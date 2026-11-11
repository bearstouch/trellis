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
    /// `currentTab` (FR-AG17): the focused pane itself, in place of its idle shell.
    public enum AgentPlacement: Sendable { case split, tab, currentTab }
    static let agentNotificationsKey = "agents.notifications"
    static let typedAgentWiringKey = "agents.typedWiring"

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

    /// Looks each agent up on the login shell's PATH; the Agents view shows the result (FR-AG07).
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

    /// FR-AG18: local integrated shells started from now on get a function per agent that passes the hook wiring.
    public var typedAgentWiringEnabled: Bool {
        get { preferences.object(forKey: Self.typedAgentWiringKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            preferences.set(newValue, forKey: Self.typedAgentWiringKey)
        }
    }

    // MARK: Typed agents (FR-AG18)

    /// What a shell function adds to each agent with live state: the same wiring as a launched agent (FR-AG08).
    func typedAgentWirings(helper: String) -> [TypedAgentWiring] {
        let piExtension = AgentCatalog.bundledFile(AgentCommand.piExtensionName)?.path
        return agentCatalog.definitions.compactMap { definition in
            guard definition.integration != .none else { return nil }
            let wiring = AgentCommand(definition: definition, hookHelper: helper, piExtension: piExtension).wiring
            return TypedAgentWiring(executable: (definition.executable as NSString).lastPathComponent, environment: wiring.environment, arguments: wiring.arguments)
        }
    }

    /// Gives a local integrated shell its own hook channel and the functions that hand it to a typed agent. The script
    /// keeps the channel out of the shell's environment, so only those agents see it. `brokered`: the broker holds the
    /// session, so it maps the nonce; otherwise the app's own socket does.
    func wireTypedAgents(_ configuration: inout LocalLaunchConfiguration, sessionID: UUID, brokered: Bool) {
        guard typedAgentWiringEnabled, let injection = configuration.shellIntegration, let helper = sessionBroker?.hookHelperPath else { return }
        // A shell refused before spawning never reports an exit; its nonce goes with the next shell instead.
        let live = Set(terminals.values.compactMap(\.sessionID)).subtracting([sessionID])
        agentHookNonces = agentHookNonces.filter { live.contains($0.value) }
        let wired = injection.addingAgentWiring(typedAgentWirings(helper: helper))
        guard wired != injection else { return }
        let nonce = AgentHook.makeNonce()
        if brokered, let socket = sessionBroker?.agentSocketPath {
            configuration.agentHook = AgentHookEnvironment(socket: socket, nonce: nonce)
        } else if !brokered, let socket = appAgentSocket() {
            configuration.agentHook = AgentHookEnvironment(socket: socket, nonce: nonce)
            agentHookNonces[nonce] = sessionID
        } else {
            return
        }
        configuration.shellIntegration = wired
    }

    /// The agent a pane shows, launched or typed: for its state, badge, notifications and Running row. Lifecycle (Start,
    /// Resume, the installer) stays with `agentDefinition`.
    public func paneAgent(paneID: UUID) -> AgentDefinition? { agentDefinition(paneID: paneID) ?? detectedAgent(paneID: paneID) }

    /// FR-AG18: a typed agent's state ends with its command, and a new command never inherits it.
    func clearTypedAgentState(paneID: UUID, event: ShellIntegrationEvent, state: ShellIntegrationState) {
        guard agentStates[paneID] != nil, agentLaunch(paneID: paneID) == nil else { return }
        let started: Bool
        if case .commandStart = event { started = true } else { started = false }
        if started || !state.commandRunning { agentStates.removeValue(forKey: paneID) }
    }

    // MARK: Panes

    public func agentLaunch(paneID: UUID) -> AgentLaunch? { snapshot.panes[paneID].flatMap { snapshot.sessions[$0.sessionID]?.launch.agent } }
    public func agentDefinition(paneID: UUID) -> AgentDefinition? { agentLaunch(paneID: paneID).flatMap { agentCatalog.definition($0.agentID) } }

    /// FR-AG15: the agent a shell pane's authenticated command is running. Computed from runtime shell state, so it ends with
    /// the command and is never saved. Display only: lifecycle and live state stay with `agentDefinition`, since a shell pane
    /// has no Start or Resume, and without hooks nothing would end a Working.
    public func detectedAgent(paneID: UUID) -> AgentDefinition? {
        guard agentLaunch(paneID: paneID) == nil, let state = shellStates[paneID], state.origin == .authenticated, let name = state.commandName else { return nil }
        return agentCatalog.definition(forCommand: name)
    }

    /// "Claude Code · api": the automatic title of an agent pane, and of its tab unless the user named it.
    func agentTitle(paneID: UUID) -> String? {
        if let agent = agentLaunch(paneID: paneID) {
            let name = agentCatalog.definition(agent.agentID)?.name ?? "Agent"
            return agentTitle(name: name, directory: agent.directory ?? (agent.hostID == nil ? defaultDirectory : nil), remote: agent.hostID != nil)
        }
        guard let detected = detectedAgent(paneID: paneID) else { return nil }
        return agentTitle(name: detected.name, directory: shellStates[paneID]?.currentDirectory, remote: isRemoteWorkspace(paneID: paneID))
    }

    private func agentTitle(name: String, directory: String?, remote: Bool) -> String {
        guard let directory else { return name }
        // A remote path is never this Mac's home, even when it is spelled the same.
        let folder = !remote && directory == FileManager.default.homeDirectoryForCurrentUser.path ? "~" : (directory as NSString).lastPathComponent
        return folder.isEmpty ? name : "\(name) · \(folder)"
    }

    /// The agent a tab's icon shows in place of the terminal (FR-AG09): its focused pane's, else its first running one.
    public func tabAgent(tabID: UUID) -> AgentDefinition? {
        guard let tab = snapshot.tabs[tabID] else { return nil }
        return ([tab.activePaneID] + tab.root.paneIDs).lazy.filter { self.terminals[$0]?.sessionState == .running }.compactMap { self.agentDefinition(paneID: $0) ?? self.detectedAgent(paneID: $0) }.first
    }

    /// The most urgent agent state among a tab's panes (FR-AG10): needs you, then error, working, done.
    public func agentBadge(tabID: UUID) -> (agent: AgentDefinition, state: AgentState)? {
        let rank: [AgentState: Int] = [.needsInput: 0, .error: 1, .working: 2, .done: 3]
        let badges = (snapshot.tabs[tabID]?.root.paneIDs ?? []).compactMap { id -> (agent: AgentDefinition, state: AgentState)? in
            guard let badge = agentStates[id]?.badge, let agent = paneAgent(paneID: id) else { return nil }
            return (agent, badge)
        }
        return badges.min { rank[$0.state, default: 9] < rank[$1.state, default: 9] }
    }

    /// Where a pane opened from this one starts: the shell's authenticated directory, else where the pane started.
    func inheritedDirectory(from paneID: UUID, remote: Bool) -> String? {
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
            let space = snapshot.spaces.first(where: { $0.id == tab.spaceID })
        else { return }
        let hostID = space.remoteHostID
        let launch = AgentLaunch(agentID: agentID, directory: inheritedDirectory(from: sourcePaneID, remote: hostID != nil), hostID: hostID, resume: resume)
        let paneID: UUID?
        switch placement {
        case .split:
            // A split hidden behind a maximized pane would hide the agent's first questions.
            guard maximizedPanes[tab.id] == nil else {
                errorMessage = L("Restore panes before opening an agent in a split.")
                return
            }
            paneID = await splitPane(sourcePaneID, axis: .x, startSession: false)
        case .tab:
            paneID = await createTab(spaceID: space.id, startSessions: false).flatMap { snapshot.tabs[$0]?.activePaneID }
        case .currentTab:
            paneID = await clearPaneForAgent(sourcePaneID, agentName: agentCatalog.definition(agentID)?.name ?? L("the agent")) ? sourcePaneID : nil
        }
        guard let paneID, !isClosing(paneID: paneID) else { return }
        await configureAgent(paneID: paneID, launch: launch)
    }

    /// FR-AG17: an agent is starting, running or typed in one of the tab's panes.
    public func agentRunning(inTab tabID: UUID) -> Bool {
        (snapshot.tabs[tabID]?.root.paneIDs ?? []).contains { id in
            guard let state = terminals[id]?.sessionState, [.starting, .running, .closing].contains(state) else { return false }
            return agentLaunch(paneID: id) != nil || detectedAgent(paneID: id) != nil
        }
    }

    /// FR-AG17: the pane gives its session to the agent. A running shell is ended only while it waits at an authenticated
    /// prompt, so no command is cut off, only in a tab without an agent, and only after the user confirms, since its marks
    /// don't report background or stopped jobs. Nothing is forced.
    private func clearPaneForAgent(_ paneID: UUID, agentName: String) async -> Bool {
        guard let pane = snapshot.panes[paneID], let terminal = terminals[paneID], !agentRunning(inTab: pane.tabID) else {
            errorMessage = L("An agent is already running in this tab. Open the agent in a new tab or a split.")
            return false
        }
        switch terminal.sessionState {
        case .stopped: return true
        case .exited, .failed: break
        case .running:
            func idle() -> Bool {
                guard terminals[paneID] === terminal, terminal.sessionState == .running, !isClosing(paneID: paneID), !agentRunning(inTab: pane.tabID),
                    let state = shellStates[paneID]
                else { return false }
                return state.origin == .authenticated && !state.commandRunning && !terminal.isReplaying && taskRuns[paneID]?.isActive != true
            }
            guard idle() else {
                errorMessage = L("This pane isn't at its shell prompt. Finish its command first, or open the agent in a new tab.")
                return false
            }
            guard confirmReplaceShell(agentName) else { return false }
            // Marks keep arriving while the alert is up; a command started meanwhile is never cut off.
            guard idle() else {
                errorMessage = L("This pane's shell started a command, so the agent wasn't opened there.")
                return false
            }
            guard await endRunningSession(terminal, paneID: paneID, force: false), [.exited, .failed].contains(terminal.sessionState) else {
                errorMessage = L("The shell in this pane didn't exit, so the agent wasn't opened there.")
                return false
            }
        default:
            errorMessage = L("This pane's session is still starting or closing. Try again in a moment.")
            return false
        }
        await restartPane(paneID, startSession: false)
        return terminals[paneID]?.sessionState == .stopped
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
            errorMessage = L("The agent pane could not be prepared.")
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
                errorMessage = L("The session broker could not start, so this session will end when Trellis quits.")
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
        guard let pane = snapshot.panes.values.first(where: { $0.sessionID == sessionID }) else { return }
        if let settings = AgentSettings(infoEvent: event) {
            // FR-AG19: settings only decorate a state the hooks already set.
            guard agentStates[pane.id]?.hooked == true else { return }
            applyAgentSignal(.settings(settings), paneID: pane.id)
        } else if let event = AgentEvent(rawValue: event) {
            applyAgentSignal(.hook(event), paneID: pane.id)
        }
    }

    /// A pane that adopted a kept session shows the last state and settings its hooks reported, without notifying again.
    func restoreAgentState(paneID: UUID, event: String?, info: String? = nil) {
        guard let definition = agentDefinition(paneID: paneID) else { return }
        var reducer = AgentStateReducer(integration: definition.integration)
        if let event = event.flatMap(AgentEvent.init(rawValue:)) {
            reducer.apply(.hook(event), visible: true)
            if let settings = info.flatMap(AgentSettings.init(infoEvent:)) { reducer.apply(.settings(settings), visible: true) }
        }
        agentStates[paneID] = reducer
    }

    func applyAgentSignal(_ signal: AgentSignal, paneID: UUID) {
        let agent: AgentDefinition
        if let managed = agentDefinition(paneID: paneID) {
            agent = managed
        } else {
            // FR-AG18: a typed agent has state only once its own hooks spoke; terminal signals alone would never end a Working.
            guard let typed = detectedAgent(paneID: paneID) else { return }
            if case .hook = signal {} else if agentStates[paneID]?.hooked != true { return }
            agent = typed
        }
        let current = agentStates[paneID] ?? AgentStateReducer(integration: agent.integration)
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
        guard appearance.desktopNotifications, agentNotificationsEnabled, let desktopNotifier, let agent = paneAgent(paneID: paneID),
            snapshot.panes[paneID] != nil, !agentPaneVisible(paneID), notificationLimiter.allow(paneID, at: activityNow())
        else { return }
        let needsYou = state == .needsInput
        let title = needsYou ? L("%@ needs you", agent.name) : L("%@ finished", agent.name)
        let body = needsYou ? L("Waiting for your input") : L("Finished its turn")
        desktopNotifier.post(DesktopNotification(paneID: paneID, title: title, subtitle: notificationContext(paneID: paneID), body: body))
    }

    /// FR-AG12: exit 127 before any hook spoke means the agent isn't installed where it ran, so its installer is offered.
    func agentSessionEnded(paneID: UUID, sessionID: UUID, code: Int32?, current: Bool) {
        let installed = agentInstalling.remove(sessionID) != nil
        for (nonce, id) in agentHookNonces where id == sessionID { agentHookNonces.removeValue(forKey: nonce) }
        guard current, let launch = snapshot.sessions[sessionID]?.launch.agent, let agent = agentCatalog.definition(launch.agentID) else {
            // A shell's typed agent (FR-AG18) ends with it.
            if current { agentStates.removeValue(forKey: paneID) }
            return
        }
        let hooked = agentStates[paneID]?.hooked == true
        agentStates.removeValue(forKey: paneID)
        guard code == AgentCommand.notInstalledStatus, !hooked else { return }
        if let host = launch.hostID { remoteMissingAgents[host, default: []].insert(agent.id) } else { agentAvailability[agent.id] = .missing }
        let installer = agentInstaller(agent, hostID: launch.hostID)
        agentInstallOffer = AgentInstallOffer(
            id: UUID(), paneID: paneID, agent: agent, hostID: launch.hostID, hostName: launch.hostID.map(remoteHostName) ?? L("this Mac"),
            recipe: installer.recipe, missingRequirements: installer.missingRequirements, afterInstall: installed)
    }

    /// The installer offered for an agent on a machine (FR-AG12): the recipe for its platform (a host's from its helper,
    /// else Linux), and the programs it needs that this Mac's login PATH lacks; a host's can't be checked first.
    public func agentInstaller(_ agent: AgentDefinition, hostID: UUID?) -> (recipe: AgentInstallRecipe?, missingRequirements: [String]) {
        guard hostID == nil else { return (agent.install[agentPlatform(hostID: hostID)], []) }
        let recipe = agent.install["darwin"]
        guard let path = agentLoginPath else { return (recipe, []) }
        return (recipe, recipe?.requires.filter { AgentPathProbe.resolve($0, path: path) == nil } ?? [])
    }

    /// `darwin` for this Mac; a host's OS as its helper last reported it, else `linux`.
    public func agentPlatform(hostID: UUID?) -> String {
        guard let hostID else { return "darwin" }
        return remoteHostPlatforms[hostID] ?? remoteHosts?.preferences[hostID]?.helper.map { $0.system.lowercased() } ?? "linux"
    }

    /// Runs the vendor's installer in the same pane, in the login shell, then the agent (FR-AG12).
    public func installAgent(_ offer: AgentInstallOffer) async {
        agentInstallOffer = nil
        guard offer.recipe != nil, agentLaunch(paneID: offer.paneID)?.agentID == offer.agent.id else { return }
        agentInstallPanes.insert(offer.paneID)
        forgetMissingAgent(offer.agent.id, hostID: offer.hostID)
        await restartAgent(paneID: offer.paneID, resume: false)
        // A launch refused before its command was built never took the mark; a later start must not run the installer.
        agentInstallPanes.remove(offer.paneID)
    }

    /// The installer is about to change whether the agent is there, so a missing mark no longer holds.
    func forgetMissingAgent(_ agentID: String, hostID: UUID?) {
        if let hostID { remoteMissingAgents[hostID]?.remove(agentID) } else { agentAvailability.removeValue(forKey: agentID); agentPathCheckedAt = nil }
    }

    /// An agent run's `since` (API v2): when each pane's agent entered its current state.
    func noteAgentStateTimes(from old: [UUID: AgentStateReducer]) {
        for (id, reducer) in agentStates where old[id]?.state != reducer.state { agentStateSince[id] = activityNow() }
        if agentStateSince.count > agentStates.count { agentStateSince = agentStateSince.filter { agentStates[$0.key] != nil } }
    }
}
