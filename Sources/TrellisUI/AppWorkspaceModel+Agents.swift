import AppKit
import Foundation
import TrellisBroker
import TrellisCore
import TrellisTerminal

/// Whether an agent is on this Mac's login PATH (FR-AG07); only ever recorded from a check.
public enum AgentAvailability: Equatable, Sendable {
    case checking, installed(path: String), missing
}

/// An agent wasn't found where it was launched (FR-AG12). The sheet names the machine, the vendor's own command and what
/// it needs; declining runs nothing.
public struct AgentInstallOffer: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let paneID: UUID
    public let agent: AgentDefinition
    /// nil: this Mac.
    public let hostID: UUID?
    public let hostName: String
    public let recipe: AgentInstallRecipe?
    /// Requirements the login PATH doesn't have; empty on a host, where they can't be checked first.
    public let missingRequirements: [String]
    /// The installer already ran in this pane and the agent still wasn't found.
    public let afterInstall: Bool
}

extension AppWorkspaceModel {
    public enum AgentPlacement: Sendable { case split, tab }
    static let agentNotificationsKey = "agents.notifications"

    // MARK: Catalog (FR-AG01–FR-AG03)

    public func reloadAgentCatalog() {
        agentCatalog = AgentCatalog.load(userDirectory: agentsDirectory)
        agentAvailability = [:]
        agentPathCheckedAt = nil
        AgentIconImages.clear()
    }

    /// Opens the user's Agents folder in Finder, creating it owner-only first.
    public func revealAgentsFolder() {
        guard let agentsDirectory else { return }
        try? FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([agentsDirectory])
    }

    /// Looks each agent up on the login shell's PATH; the Agent menu shows the result (FR-AG07).
    public func refreshAgentAvailability() {
        // Each check starts an interactive login shell, so a header appearing doesn't repeat a fresh one.
        let fresh = agentPathCheckedAt.map { activityNow().timeIntervalSince($0) < 60 } ?? false
        guard agentPathProbe == nil, !fresh else { return }
        let agents = agentCatalog.definitions.map { ($0.id, $0.executable) }
        for (id, _) in agents where agentAvailability[id] == nil { agentAvailability[id] = .checking }
        let shell = defaultShell
        agentPathProbe = Task { [weak self] in
            let path = await Task.detached { AgentPathProbe.loginPath(shell: shell) }.value
            guard let self else { return }
            agentLoginPath = path ?? agentLoginPath
            for (id, executable) in agents {
                if let found = AgentPathProbe.resolve(executable, path: path) {
                    agentAvailability[id] = .installed(path: found)
                } else if path != nil {
                    agentAvailability[id] = .missing
                } else {
                    agentAvailability.removeValue(forKey: id)
                }
            }
            agentPathProbe = nil
            agentPathCheckedAt = activityNow()
        }
    }

    public var agentNotificationsEnabled: Bool {
        get { preferences.object(forKey: Self.agentNotificationsKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            preferences.set(newValue, forKey: Self.agentNotificationsKey)
        }
    }

    // MARK: Panes

    public func agentLaunch(paneID: UUID) -> AgentLaunch? { snapshot.panes[paneID].flatMap { snapshot.sessions[$0.sessionID]?.launch.agent } }
    public func agentDefinition(paneID: UUID) -> AgentDefinition? { agentLaunch(paneID: paneID).flatMap { agentCatalog.definition($0.agentID) } }

    /// "Claude Code · api": the automatic title of an agent pane, and of its tab unless the user named it.
    func agentTitle(paneID: UUID) -> String? {
        guard let agent = agentLaunch(paneID: paneID) else { return nil }
        let name = agentCatalog.definition(agent.agentID)?.name ?? "Agent"
        guard let directory = agent.directory ?? (agent.hostID == nil ? defaultDirectory : nil) else { return name }
        let folder = agent.hostID == nil && directory == FileManager.default.homeDirectoryForCurrentUser.path ? "~" : (directory as NSString).lastPathComponent
        return folder.isEmpty ? name : "\(name) · \(folder)"
    }

    /// The agent a tab's icon shows in place of the terminal (FR-AG09): its focused pane's, else its first running one.
    public func tabAgent(tabID: UUID) -> AgentDefinition? {
        guard let tab = snapshot.tabs[tabID] else { return nil }
        return ([tab.activePaneID] + tab.root.paneIDs).lazy.filter { self.terminals[$0]?.sessionState == .running }.compactMap(agentDefinition(paneID:)).first
    }

    /// The most urgent agent state among a tab's panes (FR-AG10): needs you, then error, working, done.
    public func agentBadge(tabID: UUID) -> (agent: AgentDefinition, state: AgentState)? {
        let rank: [AgentState: Int] = [.needsInput: 0, .error: 1, .working: 2, .done: 3]
        let badges = (snapshot.tabs[tabID]?.root.paneIDs ?? []).compactMap { id -> (agent: AgentDefinition, state: AgentState)? in
            guard let badge = agentStates[id]?.badge, let agent = agentDefinition(paneID: id) else { return nil }
            return (agent, badge)
        }
        return badges.min { rank[$0.state, default: 9] < rank[$1.state, default: 9] }
    }

    /// Where an agent opened from this pane starts: the shell's authenticated directory, else where the pane started.
    private func agentDirectory(from paneID: UUID, remote: Bool) -> String? {
        let launch = snapshot.panes[paneID].flatMap { snapshot.sessions[$0.sessionID]?.launch }
        if remote {
            if let directory = remoteWorkingDirectory(paneID: paneID) { return directory }
            switch launch {
            case .remoteShell(_, let directory)?: return directory
            case .agent(let agent)?: return agent.directory
            default: return nil
            }
        }
        if let directory = currentDirectory(paneID: paneID) { return directory }
        let started: String?
        switch launch {
        case .shell(let directory)?, .process(_, _, let directory)?: started = directory
        case .agent(let agent)?: started = agent.directory
        default: started = nil
        }
        return started.flatMap { SystemLaunchFileAccess().isAccessibleDirectory($0) ? $0 : nil }
    }

    /// FR-AG07: a new tab (or a split beside `sourcePaneID`) runs the agent in that pane's directory, on its host.
    public func launchAgent(_ agentID: String, from sourcePaneID: UUID, placement: AgentPlacement = .tab, resume: Bool = false) async {
        guard !shuttingDown, agentCatalog.definition(agentID) != nil, let pane = snapshot.panes[sourcePaneID], let tab = snapshot.tabs[pane.tabID],
            let window = snapshot.windows.first(where: { $0.id == tab.windowID })
        else { return }
        let hostID = window.remoteHostID
        let launch = AgentLaunch(agentID: agentID, directory: agentDirectory(from: sourcePaneID, remote: hostID != nil), hostID: hostID, resume: resume)
        let paneID: UUID?
        switch placement {
        case .split:
            // A split hidden behind a maximized pane would hide the agent's first questions.
            guard maximizedPanes[tab.id] == nil else {
                errorMessage = "Restore panes before opening an agent in a split."
                return
            }
            paneID = await splitPane(sourcePaneID, axis: .x, startSession: false)
        case .tab:
            paneID = await createTab(windowID: window.id, startSessions: false).flatMap { snapshot.tabs[$0]?.activePaneID }
        }
        guard let paneID, !isClosing(paneID: paneID) else { return }
        await configureAgent(paneID: paneID, launch: launch)
    }

    /// Restart or Resume (FR-AG06): a new session in the same pane; `resume` continues the agent's last conversation.
    public func restartAgent(paneID: UUID, resume: Bool) async {
        guard var launch = agentLaunch(paneID: paneID), let terminal = terminals[paneID] else { return }
        launch.resume = resume
        if terminal.sessionState == .exited || terminal.sessionState == .failed { await restartPane(paneID, startSession: false) }
        guard terminals[paneID]?.sessionState == .stopped, !isClosing(paneID: paneID) else { return }
        await configureAgent(paneID: paneID, launch: launch)
    }

    private func configureAgent(paneID: UUID, launch: AgentLaunch) async {
        do {
            publish(try await service.execute(.configureStoppedSession(paneID: paneID, launch: .agent(launch))).snapshot)
        } catch {
            errorMessage = "The agent pane could not be prepared."
            return
        }
        await start(paneID: paneID)
    }

    /// FR-AG04: an agent session after `start` committed its attempt, on its host or here. Kept out of `start`'s launch switch:
    /// an extra suspension point there made Swift 6.3's task allocator abort ("freed pointer was not the last allocation").
    func startAgent(_ agent: AgentLaunch, paneID: UUID, terminal: NativeTerminal, request: SessionLaunchRequest, environment: [String: String], quietly: Bool) async {
        if let hostID = agent.hostID {
            await startRemote(paneID: paneID, terminal: terminal, request: request, hostID: hostID, directory: agent.directory, agent: agent)
            return
        }
        func refuse(_ message: String) async {
            if terminals[paneID] === terminal { terminal.refuseLaunch(message: message) }
            if let result = try? await service.execute(
                .completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .failed(message: message)))
            {
                publish(result.snapshot)
            }
        }
        guard let configuration = await agentConfiguration(agent, paneID: paneID, sessionID: request.sessionID, environment: environment) else {
            return await refuse("This agent is no longer in the agent catalog.")
        }
        // FR-R07, as for shells: the broker keeps the agent running whatever the quit setting.
        if let sessionBroker {
            let ready = await sessionBroker.prepare()
            guard terminals[paneID] === terminal, !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled else {
                agentHookNonces = agentHookNonces.filter { $0.value != request.sessionID }
                return await refuse("Session launch was cancelled.")
            }
            if ready, let transport = sessionBroker.makeTransport(sessionID: request.sessionID) {
                terminal.useTransport(transport)
            } else if !quietly {
                errorMessage = "The session broker could not start, so this session will end when Trellis quits."
            }
        }
        await terminal.start(configuration: configuration)
        // A launch refused before spawning never reports an exit, so drop its nonce here.
        if terminal.processID == nil { agentHookNonces = agentHookNonces.filter { $0.value != request.sessionID } }
    }

    /// A local agent runs in the user's login shell through `env`, with Trellis's hook wiring when the broker's helper is
    /// available (FR-AG08); without it the agent runs with the terminal's own signals only.
    func agentConfiguration(_ agent: AgentLaunch, paneID: UUID, sessionID: UUID, environment: [String: String]) async -> LocalLaunchConfiguration? {
        guard let definition = agentCatalog.definition(agent.agentID) else { return nil }
        var hook: AgentHookEnvironment?
        if definition.integration != .none, let sessionBroker, sessionBroker.hookHelperPath != nil {
            let nonce = AgentHook.makeNonce()
            if await sessionBroker.prepare(), let socket = sessionBroker.agentSocketPath {
                hook = AgentHookEnvironment(socket: socket, nonce: nonce)
            } else if let socket = appAgentSocket() {
                hook = AgentHookEnvironment(socket: socket, nonce: nonce)
                agentHookNonces[nonce] = sessionID
            }
        }
        let command = AgentCommand(
            definition: definition, resume: agent.resume, hookHelper: hook == nil ? nil : sessionBroker?.hookHelperPath,
            piExtension: AgentCatalog.bundledFile(AgentCommand.piExtensionName)?.path)
        var line = command.line
        if agentInstallPanes.remove(paneID) != nil, let recipe = definition.install["darwin"] {
            line = recipe.command + " && " + line
            agentInstalling.insert(sessionID)
        }
        let directory = agent.directory.flatMap { SystemLaunchFileAccess().isAccessibleDirectory($0) ? $0 : nil } ?? defaultDirectory
        let (executable, arguments) = AgentShell.arguments(shell: defaultShell, line: line)
        var configuration = LocalLaunchConfiguration(executable: executable, arguments: arguments, directory: directory, environmentOverrides: environment)
        configuration.agentHook = hook
        agentStates[paneID] = AgentStateReducer(integration: definition.integration)
        return configuration
    }

    /// FR-AG12: the host's helper runs the agent in the account's login shell and gives it its own hook socket. The pi
    /// extension is written beside the helper first, since the host has no copy of the app bundle.
    func remoteAgentRequest(_ agent: AgentLaunch, paneID: UUID, sessionID: UUID, info: BrokerHostInfo, hostID: UUID) -> BrokerLoginRequest? {
        guard let definition = agentCatalog.definition(agent.agentID) else { return nil }
        remoteHostPlatforms[hostID] = info.os
        let hooks = definition.integration != .none
        let command = AgentCommand(
            definition: definition, resume: agent.resume, hookHelper: hooks ? info.executable : nil,
            piExtension: info.home + "/.trellis/agents/" + AgentCommand.piExtensionName,
            piExtensionSource: AgentCatalog.bundledFile(AgentCommand.piExtensionName).flatMap { try? String(contentsOf: $0, encoding: .utf8) })
        var line = command.line
        if agentInstallPanes.remove(paneID) != nil, let recipe = definition.install[info.os] {
            line = recipe.command + " && " + line
            agentInstalling.insert(sessionID)
        }
        agentStates[paneID] = AgentStateReducer(integration: definition.integration)
        return BrokerLoginRequest(
            sessionID: sessionID, shell: nil, directory: agent.directory, environment: LocalLaunchValidator.terminalEnvironment, integration: nil, columns: 80, rows: 24,
            command: AgentShell.remoteCommand(shell: info.shell, line: line), agentHooks: hooks)
    }

    /// Sessions the broker doesn't hold report here: a socket in a fresh owner-only folder, made on first use.
    private func appAgentSocket() -> String? {
        if let agentHookReceiver { return agentHookReceiver.path }
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("trellis-agent-" + AgentHook.makeNonce().prefix(12))
        guard mkdir(directory, 0o700) == 0 else { return nil }
        let receiver = AgentHookReceiver(path: directory + "/" + BrokerProtocol.agentSocketName, queue: .main) { [weak self] nonce, event in
            MainActor.assumeIsolated {
                guard let self, let sessionID = self.agentHookNonces[nonce] else { return }
                self.receiveAgentEvent(sessionID: sessionID, event: event)
            }
        }
        guard (try? receiver.start()) != nil else {
            rmdir(directory)
            return nil
        }
        agentHookReceiver = receiver
        return receiver.path
    }

    /// Called at quit: the app's own hook socket and its folder go away with it.
    public func stopAgentHooks() {
        guard let agentHookReceiver else { return }
        agentHookReceiver.stop()
        rmdir((agentHookReceiver.path as NSString).deletingLastPathComponent)
        self.agentHookReceiver = nil
    }

    /// Agent events from the local broker and every remote link reach the pane that holds the session.
    func observeAgentEvents(on connection: BrokerConnection) {
        connection.onAgentEvent = { [weak self] sessionID, event in self?.receiveAgentEvent(sessionID: sessionID, event: event) }
    }

    func receiveAgentEvent(sessionID: UUID, event: String) {
        guard let event = AgentEvent(rawValue: event), let pane = snapshot.panes.values.first(where: { $0.sessionID == sessionID }) else { return }
        applyAgentSignal(.hook(event), paneID: pane.id)
    }

    /// A pane that adopted a kept session shows the last state its hooks reported, without notifying again.
    func restoreAgentState(paneID: UUID, event: String?) {
        guard let definition = agentDefinition(paneID: paneID) else { return }
        var reducer = AgentStateReducer(integration: definition.integration)
        if let event = event.flatMap(AgentEvent.init(rawValue:)) { reducer.apply(.hook(event), visible: true) }
        agentStates[paneID] = reducer
    }

    func applyAgentSignal(_ signal: AgentSignal, paneID: UUID) {
        guard let current = agentStates[paneID] ?? agentDefinition(paneID: paneID).map({ AgentStateReducer(integration: $0.integration) }) else { return }
        var reducer = current
        let changed = reducer.apply(signal, visible: agentPaneVisible(paneID))
        guard reducer != agentStates[paneID] else { return }
        agentStates[paneID] = reducer
        guard changed else { return }
        refreshTerminalAccessibility()
        // Only the agent's own word notifies: a bell or OSC notification already posts its own (FR-T08).
        if case .hook = signal, reducer.state != current.state, reducer.state == .needsInput || reducer.state == .done {
            postAgentNotification(paneID: paneID, state: reducer.state)
        }
    }

    private func agentPaneVisible(_ paneID: UUID) -> Bool {
        guard let pane = snapshot.panes[paneID], presentation.selectedTab?.id == pane.tabID else { return false }
        return (maximizedPanes[pane.tabID] ?? paneID) == paneID && workspaceIsFrontmost()
    }

    /// Seeing a finished agent's tab clears its Done (FR-AG10).
    func markAgentsViewed() {
        guard let tab = presentation.selectedTab, agentStates.values.contains(where: \.unseen) else { return }
        for id in tab.root.paneIDs where agentStates[id]?.unseen == true && agentPaneVisible(id) {
            agentStates[id]?.apply(.viewed)
        }
    }

    private func postAgentNotification(paneID: UUID, state: AgentState) {
        guard appearance.desktopNotifications, agentNotificationsEnabled, let desktopNotifier, let agent = agentDefinition(paneID: paneID),
            let pane = snapshot.panes[paneID], let tab = snapshot.tabs[pane.tabID], !agentPaneVisible(paneID),
            notificationLimiter.allow(paneID, at: activityNow())
        else { return }
        let title = state == .needsInput ? "\(agent.name) needs you" : "\(agent.name) finished"
        desktopNotifier.post(DesktopNotification(paneID: paneID, title: title, body: displayTitle(tab)))
    }

    /// FR-AG12: exit 127 before any hook spoke means the agent isn't installed where it ran, so its installer is offered.
    func agentSessionEnded(paneID: UUID, sessionID: UUID, code: Int32?, current: Bool) {
        let installed = agentInstalling.remove(sessionID) != nil
        for (nonce, id) in agentHookNonces where id == sessionID { agentHookNonces.removeValue(forKey: nonce) }
        guard current, let launch = snapshot.sessions[sessionID]?.launch.agent, let agent = agentCatalog.definition(launch.agentID) else { return }
        let hooked = agentStates[paneID]?.hooked == true
        agentStates.removeValue(forKey: paneID)
        guard code == AgentCommand.notInstalledStatus, !hooked else { return }
        let platform: String
        var missing: [String] = []
        if let host = launch.hostID {
            remoteMissingAgents[host, default: []].insert(agent.id)
            platform = remoteHostPlatforms[host] ?? "linux"
        } else {
            agentAvailability[agent.id] = .missing
            platform = "darwin"
            if let path = agentLoginPath { missing = agent.install[platform]?.requires.filter { AgentPathProbe.resolve($0, path: path) == nil } ?? [] }
        }
        agentInstallOffer = AgentInstallOffer(
            id: UUID(), paneID: paneID, agent: agent, hostID: launch.hostID, hostName: launch.hostID.map(remoteHostName) ?? "this Mac",
            recipe: agent.install[platform], missingRequirements: missing, afterInstall: installed)
    }

    /// Runs the vendor's installer in the same pane, in the login shell, then the agent (FR-AG12).
    public func installAgent(_ offer: AgentInstallOffer) async {
        agentInstallOffer = nil
        guard offer.recipe != nil, agentLaunch(paneID: offer.paneID)?.agentID == offer.agent.id else { return }
        agentInstallPanes.insert(offer.paneID)
        if let host = offer.hostID { remoteMissingAgents[host]?.remove(offer.agent.id) } else { agentAvailability.removeValue(forKey: offer.agent.id); agentPathCheckedAt = nil }
        await restartAgent(paneID: offer.paneID, resume: false)
    }
}
