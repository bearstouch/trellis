import Foundation
import TrellisBroker
import TrellisCore
import TrellisTerminal

/// One launch of a library project (FR-PL06–FR-PL08): the target and folder chosen, what the target holds, and the
/// setup terminal while it runs. Runtime only.
@MainActor
public final class ProjectLaunchSession: ObservableObject, Identifiable {
    public enum Stage: Equatable {
        case checking
        /// Checked and ready: what setup will do (if anything) and what opens.
        case ready(ProjectLaunch)
        case invalid(String)
        case settingUp(ProjectLaunch)
        case failed(ProjectLaunch, String)
        case opening
    }

    public let id = UUID()
    public let project: ProjectDefinition
    @Published public var target: ProjectTarget
    @Published public var folder: String
    @Published public internal(set) var stage: Stage = .checking
    /// The setup's terminal on the target, while setup runs or after it failed.
    @Published public internal(set) var terminal: NativeTerminal?
    var checkGeneration = 0
    /// The target and folder the shown plan was checked for; the sheet acts only while they still match.
    @Published public internal(set) var checked: (target: ProjectTarget, folder: String)?
    public var isCurrent: Bool { checked.map { $0.target == target && $0.folder == folder } ?? false }

    init(project: ProjectDefinition, target: ProjectTarget) {
        self.project = project; self.target = target
        folder = ProjectLaunch.suggestedFolder(project, target: target)
    }
}

extension AppWorkspaceModel {
    /// Opens the launch sheet for a saved project, on a target it was launched on before: this Mac first, else a saved host.
    public func beginProjectLaunch(_ project: ProjectDefinition) {
        guard projectLaunch == nil else { return }
        let last = project.lastFolders.keys.sorted { a, b in a == "local" || (b != "local" && a < b) }.compactMap(ProjectTarget.init(key:)).first { target in
            if case .host(let id) = target { return commandPaletteHosts().contains { $0.id == id } }
            return true
        }
        let session = ProjectLaunchSession(project: project, target: last ?? .local)
        projectLaunch = session
        Task { await checkProjectLaunch(session) }
    }

    /// Checks the target again after the target or folder changed; a newer check wins. Only while choosing: once setup
    /// or opening started, nothing here changes the stage.
    public func checkProjectLaunch(_ session: ProjectLaunchSession) async {
        guard projectLaunch === session else { return }
        switch session.stage {
        case .checking, .ready, .invalid: break
        default: return
        }
        session.checkGeneration += 1
        let generation = session.checkGeneration
        session.stage = .checking
        let target = session.target, folder = session.folder
        session.checked = (target, folder)
        let result = await projectLaunchPlan(session.project, target: target, folder: folder)
        guard projectLaunch === session, session.checkGeneration == generation else { return }
        switch result {
        case .success(let launch): session.stage = .ready(launch)
        case .failure(let failure): session.stage = .invalid(failure.message)
        }
    }

    public func setProjectLaunchTarget(_ session: ProjectLaunchSession, _ target: ProjectTarget) {
        guard session.target != target else { return }
        session.target = target
        session.folder = ProjectLaunch.suggestedFolder(session.project, target: target)
        Task { await checkProjectLaunch(session) }
    }

    public func cancelProjectLaunch(_ session: ProjectLaunchSession) {
        guard projectLaunch === session else { return }
        // Clones that finished stay. One still running gets a hangup, so git removes its partial folder (a kill would
        // leave a broken checkout the next check takes as present), then a kill after 2 s. The terminal is kept until it
        // ends: dropping it would kill a local setup at once, and a host's helper releases the session only on its exit.
        if let terminal = session.terminal, [.starting, .running].contains(terminal.sessionState) {
            terminal.onExit = { [terminal] _ in terminal.onExit = nil }
            terminal.requestTermination(force: false)
            Task { [terminal] in
                try? await Task.sleep(for: .seconds(2))
                if [.starting, .running, .closing].contains(terminal.sessionState) { terminal.requestTermination(force: true) }
            }
        }
        session.terminal = nil
        projectLaunch = nil
    }

    /// The launch resolved for its target and checked there: the project folder, and each checkout's state.
    private func projectLaunchPlan(_ project: ProjectDefinition, target: ProjectTarget, folder: String) async -> Result<ProjectLaunch, ProjectSupportFailure> {
        switch target {
        case .local:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard var launch = ProjectLaunch.resolve(project, target: target, folder: folder, home: home) else {
                return .failure(
                    ProjectSupportFailure("Choose a folder such as ~/code/\(ProjectLaunch.suggestedFolder(project, target: .host(UUID()))), other than your home folder, without quotes, $, backticks, backslashes or !."))
            }
            let manager = FileManager.default
            launch.check(
                exists: { (try? manager.attributesOfItem(atPath: $0)) != nil },
                isDirectory: { path in
                    var isDirectory: ObjCBool = false; return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                })
            return .success(launch)
        case .host(let hostID):
            guard let connection = await projectHostConnection(hostID) else {
                var reason = "Check the host, then try again."
                if case .disconnected(let message?)? = remoteLinks[hostID] { reason = message }
                return .failure(ProjectSupportFailure("Couldn't connect to \(remoteHostName(hostID)). \(reason)"))
            }
            guard let home = connection.hostInfo?.home, let resolved = ProjectLaunch.resolve(project, target: target, folder: folder, home: home) else {
                return .failure(
                    ProjectSupportFailure(
                        "Choose a folder inside your home folder on \(remoteHostName(hostID)), such as code/\(ProjectLaunch.suggestedFolder(project, target: target)), without .., quotes, $, backticks, backslashes or !.")
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
            remoteLinks[hostID] = .disconnected(RemoteHostsModel.message(for: failure))
            return nil
        }
    }

    // MARK: Setup (FR-PL07)

    /// Runs the setup script in a terminal on the target; when it succeeds the window opens.
    public func runProjectSetup(_ session: ProjectLaunchSession) async {
        guard projectLaunch === session else { return }
        let launch: ProjectLaunch
        switch session.stage {
        case .ready(let ready), .failed(let ready, _): launch = ready
        default: return
        }
        // A check still in flight must not put the sheet back to Ready while setup runs.
        session.checkGeneration += 1
        let terminal = NativeTerminal()
        session.terminal = terminal
        session.stage = .settingUp(launch)
        terminal.onExit = { [weak self, weak session] code in
            guard let self, let session, self.projectLaunch === session, case .settingUp(let running) = session.stage else { return }
            if code == 0 {
                Task {
                    // Folders that appeared are looked at again, so the plan reconciles against what is there now. The
                    // sheet stays on Setting Up meanwhile, so the target and folder can't change under it.
                    let result = await self.projectLaunchPlan(running.project, target: running.target, folder: running.folder)
                    guard self.projectLaunch === session, case .settingUp = session.stage else { return }
                    switch result {
                    case .success(let checked): await self.openProjectLaunch(session, checked)
                    case .failure(let failure): session.stage = .failed(running, failure.message)
                    }
                }
            } else {
                session.stage = .failed(running, code.map { "Setup stopped with exit status \($0). Check the output, then retry." } ?? "Setup ended without an exit status.")
            }
        }
        switch launch.target {
        case .local:
            // csh and tcsh take -l only as their sole flag, so their setup runs in a POSIX login shell, as on hosts.
            let shell = ["csh", "tcsh"].contains(URL(fileURLWithPath: defaultShell).lastPathComponent) ? "/bin/sh" : defaultShell
            await terminal.start(
                configuration: LocalLaunchConfiguration(
                    executable: shell, arguments: ["-l", "-c", launch.setupCommand], directory: FileManager.default.homeDirectoryForCurrentUser.path))
        case .host(let hostID):
            guard let connection = remoteHosts?.workspaceConnection(hostID) else {
                session.stage = .failed(launch, "\(remoteHostName(hostID)) isn't connected. Reconnect, then retry.")
                return
            }
            // A v2 helper would ignore the command and start an interactive shell instead (FR-RW18).
            guard connection.protocolVersion >= 3 else {
                session.stage = .failed(launch, "The Trellis helper on \(remoteHostName(hostID)) is older than this version. Update it in Hosts (Update Helper…), then retry.")
                return
            }
            let transport = RemoteSessionTransport(sessionID: UUID(), hostID: hostID, connection: connection)
            // Resumed with the host's panes after a drop, never offered as an orphan, and Cancel's hangup is kept until then.
            wire(transport)
            await terminal.start(
                remote: transport,
                request: BrokerLoginRequest(
                    sessionID: transport.sessionID, shell: nil, directory: nil, environment: LocalLaunchValidator.terminalEnvironment, integration: nil, columns: 80,
                    rows: 24, command: launch.setupCommand),
                nonce: nil)
        }
    }

    // MARK: Opening (FR-PL08)

    /// Creates or reconciles the project's window, starts the panes this launch created and types their commands once.
    public func openProjectLaunch(_ session: ProjectLaunchSession, _ launch: ProjectLaunch) async {
        guard projectLaunch === session else { return }
        session.checkGeneration += 1
        session.stage = .opening
        guard !isRestoring, recoveryMessage == nil, !shuttingDown else {
            session.stage = .failed(launch, "The workspace isn't available yet. Try again once it has loaded.")
            return
        }
        let bindings: [String: LayoutBinding]
        do { bindings = try layoutBindings(launch.namespace) } catch {
            session.stage = .failed(launch, "Saved layout bindings could not be read, so the project can't open.")
            return
        }
        let snapshot = snapshot
        let plan: LayoutPlan
        switch launch.target {
        case .local:
            plan = LayoutPlanner.plan(
                launch.layout, bindings: bindings, snapshot: snapshot, home: FileManager.default.homeDirectoryForCurrentUser.path, hostExists: { _ in false },
                directoryExists: { path in
                    var isDirectory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                },
                keepLiveLaunches: true, keepOmittedPanes: true)
        case .host(let hostID):
            guard let connection = remoteHosts?.workspaceConnection(hostID), let home = connection.hostInfo?.home else {
                session.stage = .failed(launch, "\(remoteHostName(hostID)) isn't connected. Reconnect, then try again.")
                return
            }
            plan = await RemoteFacts(connection: connection).evaluate { lookup in
                LayoutPlanner.plan(
                    launch.layout, bindings: bindings, snapshot: snapshot, home: home, hostExists: { _ in false }, directoryExists: lookup.isDirectory,
                    keepLiveLaunches: true, keepOmittedPanes: true, remoteHostID: hostID)
            }
        }
        guard plan.canApply, projectLaunch === session else {
            session.stage = .failed(launch, "The project can't open: " + (plan.errors + plan.conflicts).map(\.text).joined(separator: " "))
            return
        }
        do { _ = try await automationApplyLayout(plan, namespace: launch.namespace) } catch {
            session.stage = .failed(launch, "The workspace changed or is busy, so the project wasn't opened. Try again.")
            return
        }
        // A cancel during the apply may have let another launch begin; its sheet stays.
        if projectLaunch === session { projectLaunch = nil }
        guard let windowID = plan.bindings[ProjectLaunch.windowKey()]?.id else { return }
        pruneProjectState()
        for (key, paneID) in plan.createdPanes {
            if let command = launch.commands[key], let sessionID = sessionID(ofPane: paneID) { pendingProjectCommands[sessionID] = command }
        }
        await selectWindow(windowID)
        let integration: Bool
        switch launch.target {
        case .local: integration = shellGetsIntegration
        case .host(let hostID): integration = remoteShellGetsIntegration(hostID)
        }
        for (_, paneID) in plan.createdPanes {
            let sessionID = sessionID(ofPane: paneID)
            try? await automationStartSession(paneID, launch: nil, environment: [:])
            // A start that was refused or skipped drops the command, so a later manual start never types it.
            if let sessionID, ![.starting, .running].contains(self.snapshot.sessions[sessionID]?.state) { pendingProjectCommands.removeValue(forKey: sessionID) }
            // Without integration there is no prompt mark to wait for; the PTY holds the command until the shell reads it.
            if !integration { submitProjectCommand(paneID: paneID) }
        }
        onProjectLaunched?(launch.project.id, launch.target, launch.folder)
    }

    private func sessionID(ofPane paneID: UUID) -> UUID? { snapshot.panes[paneID]?.sessionID }
}
