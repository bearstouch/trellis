import AppKit
import Darwin
import TrellisBroker
import TrellisCore
import TrellisTerminal

/// A remote workspace host's link as the sidebar and pane headers show it (FR-RW07, FR-RW16): words and a symbol.
public enum RemoteLinkDisplay: Equatable, Sendable {
    case connecting, connected
    /// An automatic attempt is due at `at` (FR-RW07).
    case reconnecting(attempt: Int, at: Date)
    /// Automatic attempts wait for the network.
    case offline
    /// Automatic attempts stopped: ssh needs a password, a passphrase or a host-key decision. The words are shown; the
    /// reason code is what protocol 2 reports.
    case needsInput(String, reason: RemoteLinkReason = .needsInput)
    /// With why, when known; nothing is retried on its own. nil reason: nothing recorded yet.
    case disconnected(String?, reason: RemoteLinkReason? = nil)

    public var label: String {
        switch self {
        case .connecting: L("Connecting…")
        case .connected: L("Connected")
        case .reconnecting(let attempt, _): L("Reconnecting (attempt %d)…", attempt)
        case .offline: L("Offline, waiting for the network")
        case .needsInput: L("Reconnect needs you")
        case .disconnected: L("Disconnected")
        }
    }
    public var symbol: String {
        switch self {
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle"
        case .offline: "wifi.slash"
        case .needsInput: "person.crop.circle.badge.exclamationmark"
        case .disconnected: "bolt.horizontal.circle"
        }
    }
    /// Why, for the help text and VoiceOver.
    public var detail: String? {
        switch self {
        case .needsInput(let reason, _): reason
        case .disconnected(let reason, _): reason
        case .reconnecting(_, let at): L("Next attempt %@.", at.formatted(.relative(presentation: .named)))
        default: nil
        }
    }
    var isUp: Bool { self == .connected || self == .connecting }

    /// A failed connection as the sidebar shows it: an automatic attempt that needs the person stops at **Reconnect…**.
    @MainActor init(_ failure: RemoteHostLink.Failure) {
        if case .needsInput(let text, let reason) = failure {
            self = .needsInput(text, reason: reason)
        } else {
            self = .disconnected(RemoteHostsModel.message(for: failure), reason: failure.reason)
        }
    }
}

/// Remote workspaces (FR-RW01–FR-RW09): spaces bound to a saved host whose sessions the host's helper owns.
extension AppWorkspaceModel {
    /// Opens a space bound to `host` and starts its first shell there, in `directory` or home; the helper is installed
    /// first if needed and allowed.
    @discardableResult
    public func openRemoteWorkspace(host: SavedHost, directory: String? = nil) async -> UUID? {
        guard remoteHosts != nil, !isRestoring, recoveryMessage == nil, !shuttingDown, !Task.isCancelled else { return nil }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.createRemoteSpace(name: host.name, hostID: host.id))
            guard let id = result.createdSpaceID, let space = result.snapshot.spaces.first(where: { $0.id == id }),
                let tab = result.snapshot.tabs[space.activeTabID], let pane = result.snapshot.panes[tab.activePaneID]
            else { return nil }
            attachTerminal(pane)
            publish(result.snapshot)
            if let directory { publish(try await service.execute(.configureStoppedSession(paneID: pane.id, launch: .remoteShell(hostID: host.id, directory: directory))).snapshot) }
            await start(paneID: pane.id)
            return id
        } catch { errorMessage = L("The remote workspace could not be created."); return nil }
    }

    public func isRemoteWorkspace(paneID: UUID) -> Bool {
        snapshot.panes[paneID].flatMap { snapshot.sessions[$0.sessionID]?.launch.remoteHostID } != nil
    }

    /// A remote workspace pane's directory on its host, from its shell's nonce-checked marks (FR-RW05). Never used for
    /// anything local: `currentDirectory(paneID:)` stays nil for these panes.
    public func remoteWorkingDirectory(paneID: UUID) -> String? {
        guard isRemoteWorkspace(paneID: paneID), let state = shellStates[paneID], state.origin == .authenticated else { return nil }
        return state.currentDirectory
    }

    public func remoteHostName(_ id: UUID) -> String { commandPaletteHosts().first { $0.id == id }?.name ?? "Missing host" }

    /// FR-RW04: the account's login shell on the host, in `directory` or home, with Trellis's integration when its scripts
    /// are installed beside the helper.
    func startRemote(paneID: UUID, terminal: NativeTerminal, request: SessionLaunchRequest, hostID: UUID, directory: String?, agent: AgentLaunch? = nil) async {
        func refuse(_ message: String) async {
            if terminals[paneID] === terminal { terminal.refuseLaunch(message: message) }
            if let result = try? await service.execute(
                .completeLaunch(sessionID: request.sessionID, attemptID: request.attemptID, outcome: .failed(message: message)))
            {
                publish(result.snapshot)
            }
        }
        guard let remoteHosts else { return await refuse("Remote workspaces aren’t available in this build.") }
        guard let host = await resolveHost?(hostID) else {
            return await refuse("This saved host was deleted or the host library could not be read. Close this workspace or open the host again.")
        }
        let (connected, failure) = await remoteConnection(host, remoteHosts: remoteHosts, interactive: true)
        guard let connection = connected else {
            // The failure message is saved and returned by the API, so it stays English whatever the app shows.
            let english = Localization.$sourceTextOnly.withValue(true) { failure.map(RemoteHostsModel.message(for:)) ?? "The connection failed." }
            return await refuse("Could not connect to \(host.name). \(english)")
        }
        guard terminals[paneID] === terminal, !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled else {
            return await refuse("Session launch was cancelled.")
        }
        observeAgentEvents(on: connection)
        if let agent {
            // An agent runs as a login shell's command, which helpers older than protocol 3 can't do (FR-RW18).
            guard connection.protocolVersion >= 3, let info = connection.hostInfo else {
                return await refuse("Update the Trellis helper on \(host.name) to run agents there: Hosts → Update Helper….")
            }
            guard let login = remoteAgentRequest(agent, paneID: paneID, sessionID: request.sessionID, info: info, hostID: hostID) else {
                return await refuse("This agent is no longer in the agent catalog.")
            }
            let transport = RemoteSessionTransport(sessionID: request.sessionID, hostID: hostID, connection: connection)
            wire(transport)
            await terminal.start(remote: transport, request: login, nonce: nil)
            return
        }
        let transport = RemoteSessionTransport(sessionID: request.sessionID, hostID: hostID, connection: connection)
        wire(transport)
        var integration: BrokerIntegration?
        var nonce: String?
        // Planned here from the host's own facts; the helper applies it only to that shell, and only if the script exists.
        if shellIntegrationEnabled, let info = connection.hostInfo, let kind = ShellIntegrationKind(executable: info.shell) {
            let resources = BrokerFiles.parent(info.executable) + "/integration"
            let token = ShellIntegrationInjection.makeNonce()
            if let plan = ShellIntegrationInjection.plan(kind: kind, arguments: ["-l"], inheritedEnvironment: [:], resourceDirectory: resources, nonce: token) {
                integration = BrokerIntegration(shell: info.shell, arguments: plan.arguments, environment: plan.environment, scriptPath: plan.scriptPath)
                nonce = token
            }
        }
        let login = BrokerLoginRequest(
            sessionID: request.sessionID, shell: nil, directory: directory, environment: LocalLaunchValidator.terminalEnvironment, integration: integration,
            columns: 80, rows: 24)
        await terminal.start(remote: transport, request: login, nonce: nonce)
    }

    /// The host's shared link for starting sessions there, connected when needed: the sidebar shows the attempt and, on
    /// failure, why (words, and a reason code for protocol 2). `install` overrides the host's helper policy (protocol 2
    /// applies its helperInstall rule); nil installs as the app does, asking unless the host's auto-install is on.
    func remoteConnection(_ host: SavedHost, remoteHosts: RemoteHostsModel, interactive: Bool, install: RemoteHostLink.InstallPolicy? = nil) async -> (
        connection: BrokerConnection?, failure: RemoteHostLink.Failure?
    ) {
        let hostID = host.id
        let wasConnected = remoteLinks[hostID] == .connected
        if !wasConnected { remoteLinks[hostID] = .connecting }
        let linked = await remoteHosts.workspaceLink(host, interactive: interactive, install: install)
        guard case .success(let link) = linked, let connection = link.connection else {
            remoteLinks[hostID] = linked.failure.map(RemoteLinkDisplay.init) ?? .disconnected(L("The connection failed."), reason: .unknown)
            return (nil, linked.failure)
        }
        remoteLinks[hostID] = .connected
        // FR-RW09: the host is reachable again, so its other panes resume or re-attach now rather than waiting for Reconnect.
        // None to resume before the first space on the host exists (protocol 2 connects before creating it).
        if !wasConnected, hasRemoteWorkspace(hostID) { Task { await reconnectRemote(hostID: hostID, interactive: false) } }
        return (connection, nil)
    }

    func wire(_ transport: RemoteSessionTransport) {
        let hostID = transport.hostID, sessionID = transport.sessionID
        transport.onSignalWhileDisconnected = { [weak self] _ in self?.pendingRemoteHangups[hostID, default: []].insert(sessionID) }
        transport.onLinkChanged = { [weak self] _ in self?.objectWillChange.send() }
    }

    func remoteLinkChanged(_ host: UUID, _ state: RemoteHostLink.State) {
        guard !shuttingDown else { return }
        switch state {
        case .connected: remoteLinks[host] = .connected
        case .connecting, .installing: remoteLinks[host] = .connecting
        // A link that was up and went quiet or closed is retried on its own (FR-RW07).
        case .failed(.lost): remoteReconnector.lost(host)
        case .failed(let failure): remoteLinks[host] = .disconnected(RemoteHostsModel.message(for: failure), reason: failure.reason)
        case .closed, .idle: if remoteLinks[host] == .connected { remoteLinks[host] = .disconnected(nil, reason: .closed) }
        }
    }

    /// At launch: every host with a remote workspace is tried without prompting, and its panes re-attach (FR-RW09).
    func reattachRemoteSessions() async {
        for host in Set(snapshot.spaces.compactMap(\.remoteHostID)) where !shuttingDown {
            await remoteReconnector.attempt(host, interactive: false)
        }
    }

    /// A space bound to the host, a project setup running there, or a hangup still to send (a setup cancelled while
    /// disconnected): each needs the link back after a drop (FR-RW07).
    public func hasRemoteWorkspace(_ hostID: UUID) -> Bool {
        snapshot.spaces.contains { $0.remoteHostID == hostID } || projectLaunch?.terminal?.remoteTransport?.hostID == hostID
            || pendingRemoteHangups[hostID]?.isEmpty == false
    }

    /// The host's terminals: its panes, and a project setup running there (FR-PL07), which is in no pane.
    private func remoteTerminals(_ hostID: UUID) -> [NativeTerminal] {
        (Array(terminals.values) + [projectLaunch?.terminal].compactMap { $0 }).filter { $0.remoteTransport?.hostID == hostID }
    }

    /// A live session on the host still waiting for its pane to re-attach. One that ended or was closed while the link
    /// was down keeps `linkLost` but never resumes, so it doesn't count.
    func hasLostPanes(_ hostID: UUID) -> Bool {
        remoteTerminals(hostID).contains { $0.remoteTransport?.linkLost == true && $0.remoteTransport?.isRunning == true }
    }

    /// The host a tab's panes can't reach, from the drop until they are back (FR-RW07). `.connecting` counts as up for a
    /// first connection, but a retry stays down, or the tab would look fine for as long as ssh is trying.
    public func tabLinkDown(tabID: UUID) -> (hostName: String, link: RemoteLinkDisplay)? {
        guard let tab = snapshot.tabs[tabID] else { return nil }
        for paneID in tab.root.paneIDs {
            guard let pane = snapshot.panes[paneID], let hostID = snapshot.sessions[pane.sessionID]?.launch.remoteHostID else { continue }
            let link = remoteLinks[hostID] ?? .disconnected(nil)
            let transport = terminals[paneID]?.remoteTransport
            let lost = transport?.linkLost == true && transport?.isRunning == true
            let retrying = link == .connecting && remoteReconnector.attemptCount(hostID) > 0
            // The link is set to connected before panes re-attach; the tab doesn't say Connected beside a red line.
            if lost || !link.isUp || retrying { return (remoteHostName(hostID), link == .connected ? .connecting : link) }
        }
        return nil
    }

    /// **Reconnect…** (`interactive`: ssh may ask in the console) or **Retry Now**, through the reconnector, which
    /// schedules the next automatic attempt if this one fails for a reason a retry can fix (FR-RW07). Returns why this
    /// attempt failed (`.cancelled` when none was made); `install` as in `remoteConnection`.
    @discardableResult
    public func reconnectRemote(hostID: UUID, interactive: Bool = true, install: RemoteHostLink.InstallPolicy? = nil) async -> RemoteHostLink.Failure? {
        await remoteReconnector.attempt(hostID, interactive: interactive, install: install)
    }

    /// Connects to `hostID` again: live panes resume where they stopped, restored panes adopt their sessions, and
    /// sessions closed while it was unreachable are hung up. Returns why it failed, or nil.
    func connectRemote(hostID: UUID, interactive: Bool, install: RemoteHostLink.InstallPolicy? = nil) async -> RemoteHostLink.Failure? {
        // One at a time per host: two passes would attach the same sessions twice.
        guard let remoteHosts, !shuttingDown, remoteReconnecting.insert(hostID).inserted else { return .cancelled }
        defer { remoteReconnecting.remove(hostID) }
        guard let host = await resolveHost?(hostID) else {
            remoteLinks[hostID] = .disconnected(L("This saved host no longer exists."), reason: .hostMissing)
            return .cancelled
        }
        // Quit while the host was being resolved: no link is opened after the others were closed.
        guard !shuttingDown else { return .cancelled }
        remoteLinks[hostID] = .connecting
        let linked = await remoteHosts.workspaceLink(host, interactive: interactive, install: install)
        guard case .success(let link) = linked, let connection = link.connection else {
            let failure = linked.failure ?? .lost
            remoteLinks[hostID] = .disconnected(RemoteHostsModel.message(for: failure), reason: failure.reason)
            return failure
        }
        remoteLinks[hostID] = .connected
        observeAgentEvents(on: connection)
        let hungUp = pendingRemoteHangups.removeValue(forKey: hostID) ?? []
        for id in hungUp { connection.post(.signal(sessionID: id, signal: SIGHUP)) }
        let resumable = remoteTerminals(hostID).compactMap { terminal in terminal.remoteTransport.flatMap { transport in terminalSize(terminal).map { (transport, $0) } } }
        _ = await RemoteSessionTransport.resume(resumable, on: connection)
        // A session just hung up can still be listed as running; it is never offered as an orphan.
        await adoptRemoteSessions(hostID: hostID, connection: connection, ignoring: hungUp)
        return nil
    }

    private func terminalSize(_ terminal: NativeTerminal) -> TerminalSize? {
        let window = terminal.getWindowSize()
        return try? TerminalSize(columns: Int(window.ws_col), rows: Int(window.ws_row))
    }

    /// Restored, stopped panes adopt the sessions the host's helper kept; ended ones show their replay; running ones no
    /// pane claims are offered Stop Them / Leave Running once per app run.
    private func adoptRemoteSessions(hostID: UUID, connection: BrokerConnection, ignoring hungUp: Set<UUID>) async {
        guard case .sessions(let records)? = try? await connection.request(.list) else { return }
        let panes = Dictionary(snapshot.panes.values.map { ($0.sessionID, $0.id) }, uniquingKeysWith: { first, _ in first })
        var orphans: [UUID] = []
        for record in records where !hungUp.contains(record.sessionID) {
            if remoteTerminals(hostID).contains(where: { $0.remoteTransport?.sessionID == record.sessionID && $0.isRunning }) { continue }
            guard let paneID = panes[record.sessionID], let terminal = terminals[paneID], terminal.sessionID == record.sessionID,
                terminal.sessionState == .stopped, snapshot.sessions[record.sessionID]?.launch.remoteHostID == hostID, let size = terminalSize(terminal)
            else {
                if !record.running { connection.post(.release(sessionID: record.sessionID)) } else if !remoteOrphansAsked.contains(record.sessionID) { orphans.append(record.sessionID) }
                continue
            }
            let transport = RemoteSessionTransport(sessionID: record.sessionID, hostID: hostID, connection: connection)
            wire(transport)
            guard let (attachment, replay) = await transport.attach(size: size), terminals[paneID] === terminal, terminal.sessionState == .stopped else { continue }
            guard attachment.record.running else {
                terminal.showEndedSession(replay: replay, exitCode: attachment.record.exitCode, while: "disconnected")
                connection.post(.release(sessionID: record.sessionID))
                continue
            }
            do { publish(try await service.execute(.adoptRunningSession(sessionID: record.sessionID, processID: attachment.record.processID)).snapshot) } catch { continue }
            installLifecycle(terminal, paneID: paneID, sessionID: record.sessionID, attemptID: nil)
            let adoption = BrokerAdoption(
                sessionID: record.sessionID, processID: attachment.record.processID, exitCode: nil, nonce: attachment.nonce, replay: replay, transport: transport,
                agentEvent: attachment.agentEvent, agentInfo: attachment.agentInfo)
            if terminal.adopt(adoption) {
                restoreAgentState(paneID: paneID, event: adoption.agentEvent, info: adoption.agentInfo)
            } else {
                enqueue(.recordSessionExit(sessionID: record.sessionID, code: nil))
            }
        }
        remoteOrphansAsked.formUnion(orphans)
        if !orphans.isEmpty, confirmStopOrphans(orphans.count) {
            for id in orphans { connection.post(.signal(sessionID: id, signal: SIGHUP)) }
        }
    }
}
