import Foundation
import TrellisBroker
import TrellisCore
import TrellisTerminal

/// A project launch without its sheet (FR-PL06–FR-PL08): checking a target, starting the setup there and opening the
/// project's space. The launch sheet and protocol 2's `project.check` and `project.launch` both go through it, so the app
/// and the API launch a project one way. Only how a host target is connected differs: the sheet connects with its console
/// and the app's install policy, the API connects first under its helperInstall rule and hands the link in.
@MainActor
struct ProjectLauncher {
    let model: AppWorkspaceModel
    /// A host target's link, connecting it if this launcher may; nil when there is none.
    let connection: @MainActor (UUID) async -> BrokerConnection?

    /// What opening created: the space and the panes made for the project's layout keys, in document order. Launching
    /// a project that is already open reconciles its space and creates no pane.
    struct Opened {
        let spaceID: UUID
        let createdSpace: Bool
        let createdPanes: [(key: String, id: UUID)]
    }

    // MARK: Checking (FR-PL06)

    /// The launch resolved for its target and checked there: the project folder, and each checkout's state.
    func plan(_ project: ProjectDefinition, target: ProjectTarget, folder: String) async -> Result<ProjectLaunch, ProjectSupportFailure> {
        switch target {
        case .local:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard var launch = ProjectLaunch.resolve(project, target: target, folder: folder, home: home) else {
                return .failure(
                    ProjectSupportFailure(
                        L("Choose a folder such as ~/code/%@, other than your home folder, without quotes, $, backticks, backslashes or !.", ProjectLaunch.suggestedFolder(project, target: .host(UUID()))),
                        reason: .folder))
            }
            let manager = FileManager.default
            launch.check(
                exists: { (try? manager.attributesOfItem(atPath: $0)) != nil },
                isDirectory: { path in
                    var isDirectory: ObjCBool = false; return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                })
            return .success(launch)
        case .host(let hostID):
            guard let connection = await connection(hostID) else {
                var reason = L("Check the host, then try again.")
                if case .disconnected(let message?, _)? = model.remoteLinks[hostID] { reason = message }
                return .failure(ProjectSupportFailure(L("Couldn't connect to %1$@. %2$@", model.remoteHostName(hostID), reason), reason: .disconnected))
            }
            guard let home = connection.hostInfo?.home, let resolved = ProjectLaunch.resolve(project, target: target, folder: folder, home: home) else {
                return .failure(
                    ProjectSupportFailure(
                        L(
                            "Choose a folder inside your home folder on %1$@, such as code/%2$@, without .., quotes, $, backticks, backslashes or !.", model.remoteHostName(hostID),
                            ProjectLaunch.suggestedFolder(project, target: target)), reason: .folder)
                )
            }
            let launch = await RemoteFacts(connection: connection).evaluate { lookup in
                var checked = resolved
                checked.check(exists: lookup.exists, isDirectory: lookup.isDirectory)
                return checked
            }
            return .success(launch)
        }
    }

    // MARK: Setup (FR-PL07)

    /// Starts the setup script in `terminal` on the target; the caller follows its exit. `environment` is added to the
    /// setup's own (the API turns git's credential prompts off, since nobody sees its terminal).
    func startSetup(_ launch: ProjectLaunch, in terminal: NativeTerminal, environment: [String: String] = [:]) async -> ProjectSupportFailure? {
        switch launch.target {
        case .local:
            // csh and tcsh take -l only as their sole flag, so their setup runs in a POSIX login shell, as on hosts.
            let shell = ["csh", "tcsh"].contains(URL(fileURLWithPath: model.defaultShell).lastPathComponent) ? "/bin/sh" : model.defaultShell
            await terminal.start(
                configuration: LocalLaunchConfiguration(
                    executable: shell, arguments: ["-l", "-c", launch.setupCommand], directory: FileManager.default.homeDirectoryForCurrentUser.path,
                    environmentOverrides: environment))
            return nil
        case .host(let hostID):
            guard let connection = model.remoteHosts?.workspaceConnection(hostID) else {
                return ProjectSupportFailure(L("%@ isn't connected. Reconnect, then retry.", model.remoteHostName(hostID)), reason: .disconnected)
            }
            // A v2 helper would ignore the command and start an interactive shell instead (FR-RW18).
            guard connection.protocolVersion >= 3 else {
                return ProjectSupportFailure(
                    L("The Trellis helper on %@ is older than this version. Update it in Hosts (Update Helper…), then retry.", model.remoteHostName(hostID)), reason: .helperOutdated)
            }
            let transport = RemoteSessionTransport(sessionID: UUID(), hostID: hostID, connection: connection)
            // Resumed with the host's panes after a drop, never offered as an orphan, and Cancel's hangup is kept until then.
            model.wire(transport)
            await terminal.start(
                remote: transport,
                request: BrokerLoginRequest(
                    sessionID: transport.sessionID, shell: nil, directory: nil, environment: LocalLaunchValidator.terminalEnvironment.merging(environment) { $1 },
                    integration: nil, columns: 80, rows: 24, command: launch.setupCommand),
                nonce: nil)
            return nil
        }
    }

    // MARK: Opening (FR-PL08)

    /// Creates or reconciles the project's space, starts the panes this launch created and types their commands once.
    /// `stillWanted` is asked just before the change (the sheet's launch may have been cancelled meanwhile); `created`
    /// runs inside the store transaction that creates a new space, and `applied` right after the change, before the
    /// panes start.
    func open(
        _ launch: ProjectLaunch, stillWanted: () -> Bool = { true }, created: (@Sendable (UUID) -> Void)? = nil, applied: () -> Void = {}
    ) async -> Result<Opened, ProjectSupportFailure> {
        guard !model.isRestoring, model.recoveryMessage == nil, !model.shuttingDown else {
            return .failure(ProjectSupportFailure(L("The workspace isn't available yet. Try again once it has loaded."), reason: .unavailable))
        }
        let bindings: [String: LayoutBinding]
        do { bindings = try model.layoutBindings(launch.namespace) } catch {
            return .failure(ProjectSupportFailure(L("Saved layout bindings could not be read, so the project can't open."), reason: .layout))
        }
        let snapshot = model.snapshot
        let plan: LayoutPlan
        switch launch.target {
        case .local:
            plan = LayoutPlanner.plan(
                launch.layout, bindings: bindings, snapshot: snapshot, home: FileManager.default.homeDirectoryForCurrentUser.path, hostExists: { _ in false },
                directoryExists: { path in
                    var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                },
                keepLiveLaunches: true, keepOmittedPanes: true, projectID: launch.project.id)
        case .host(let hostID):
            guard let connection = model.remoteHosts?.workspaceConnection(hostID), let home = connection.hostInfo?.home else {
                return .failure(ProjectSupportFailure(L("%@ isn't connected. Reconnect, then try again.", model.remoteHostName(hostID)), reason: .disconnected))
            }
            plan = await RemoteFacts(connection: connection).evaluate { lookup in
                LayoutPlanner.plan(
                    launch.layout, bindings: bindings, snapshot: snapshot, home: home, hostExists: { _ in false }, directoryExists: lookup.isDirectory,
                    keepLiveLaunches: true, keepOmittedPanes: true, remoteHostID: hostID, projectID: launch.project.id)
            }
        }
        guard plan.canApply, stillWanted(), let spaceID = plan.bindings[ProjectLaunch.spaceKey()]?.id else {
            return .failure(ProjectSupportFailure(L("The project can't open: %@", (plan.errors + plan.conflicts).map(\.text).joined(separator: " ")), reason: .layout))
        }
        let isNew = !model.snapshot.spaces.contains { $0.id == spaceID }
        var follow: (@Sendable (WorkspaceCommandResult) -> WorkspaceCommand?)?
        if let created, isNew {
            follow = { _ in
                created(spaceID)
                return nil
            }
        }
        do { _ = try await model.automationApplyLayout(plan, namespace: launch.namespace, then: follow) } catch {
            return .failure(ProjectSupportFailure(L("The workspace changed or is busy, so the project wasn't opened. Try again."), reason: .unavailable))
        }
        applied()
        model.pruneProjectState()
        for (key, paneID) in plan.createdPanes {
            if let command = launch.commands[key], let sessionID = sessionID(ofPane: paneID) { model.pendingProjectCommands[sessionID] = command }
            if let agent = launch.agents[key] { await configureAgent(paneID: paneID, agentID: agent) }
        }
        await model.selectSpace(spaceID)
        let integration: Bool
        switch launch.target {
        case .local: integration = model.shellGetsIntegration
        case .host(let hostID): integration = model.remoteShellGetsIntegration(hostID)
        }
        for (key, paneID) in plan.createdPanes {
            let sessionID = sessionID(ofPane: paneID)
            try? await model.automationStartSession(paneID, launch: nil, environment: [:])
            // A new pane never carries an installer request, and a later start of it must never run one.
            if launch.agents[key] != nil { model.agentInstallPanes.remove(paneID) }
            // A start that was refused or skipped drops the command, so a later manual start never types it.
            if let sessionID, ![.starting, .running].contains(model.snapshot.sessions[sessionID]?.state) { model.pendingProjectCommands.removeValue(forKey: sessionID) }
            // Without integration there is no prompt mark to wait for; the PTY holds the command until the shell reads it.
            if !integration { model.submitProjectCommand(paneID: paneID) }
        }
        model.onProjectLaunched?(launch.project.id, launch.target, launch.folder)
        model.liveProjectLaunched(launch.project.id, space: spaceID, target: launch.target, folder: launch.folder)
        return .success(Opened(spaceID: spaceID, createdSpace: isNew, createdPanes: plan.createdPanes))
    }

    private func sessionID(ofPane paneID: UUID) -> UUID? { model.snapshot.panes[paneID]?.sessionID }

    /// FR-PL10: a created pane that names an agent becomes that agent's pane, in the folder and on the host the layout gave
    /// it. An agent missing from the catalog still opens, and its pane says so when it starts.
    private func configureAgent(paneID: UUID, agentID: String) async {
        let snapshot = model.snapshot
        let agent: AgentLaunch
        switch snapshot.panes[paneID].flatMap({ snapshot.sessions[$0.sessionID] })?.launch {
        case .shell(let directory)?, .process(_, _, let directory)?: agent = AgentLaunch(agentID: agentID, directory: directory)
        case .remoteShell(let host, let directory)?: agent = AgentLaunch(agentID: agentID, directory: directory, hostID: host)
        default: return
        }
        if let result = try? await model.service.execute(.configureStoppedSession(paneID: paneID, launch: .agent(agent))) { model.publish(result.snapshot) }
    }
}

extension AppWorkspaceModel {
    /// The launch sheet's launcher: a host is connected with its console, under the app's install policy (FR-RW01).
    var projectLauncher: ProjectLauncher { ProjectLauncher(model: self) { [unowned self] in await self.projectHostConnection($0) } }

    /// The host's link, connecting it (with its console for prompts) when needed (FR-RW01).
    private func projectHostConnection(_ hostID: UUID) async -> BrokerConnection? {
        if let connection = remoteHosts?.workspaceConnection(hostID) { return connection }
        guard let remoteHosts, let host = await resolveHost?(hostID) else { return nil }
        remoteLinks[hostID] = .connecting
        switch await remoteHosts.workspaceLink(host, interactive: true) {
        case .success(let link):
            remoteLinks[hostID] = .connected
            return link.connection
        case .failure(let failure):
            remoteLinks[hostID] = .disconnected(RemoteHostsModel.message(for: failure), reason: failure.reason)
            return nil
        }
    }
}
