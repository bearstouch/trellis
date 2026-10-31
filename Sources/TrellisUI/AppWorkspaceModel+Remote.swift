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
    /// Automatic attempts stopped: ssh needs a password, a passphrase or a host-key decision.
    case needsInput(String)
    /// With why, when known; nothing is retried on its own.
    case disconnected(String?)

    public var label: String {
        switch self {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting(let attempt, _): "Reconnecting (attempt \(attempt))…"
        case .offline: "Offline, waiting for the network"
        case .needsInput: "Reconnect needs you"
        case .disconnected: "Disconnected"
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
        case .needsInput(let reason): reason
        case .disconnected(let reason): reason
        case .reconnecting(_, let at): "Next attempt \(at.formatted(.relative(presentation: .named)))."
        default: nil
        }
    }
    var isUp: Bool { self == .connected || self == .connecting }
}

/// Remote workspaces (FR-RW01–FR-RW09): windows bound to a saved host whose sessions the host's helper owns.
extension AppWorkspaceModel {
    /// Opens a window bound to `host` and starts its first shell there; the helper is installed first if needed and allowed.
    @discardableResult
    public func openRemoteWorkspace(host: SavedHost) async -> UUID? {
        guard remoteHosts != nil, !isRestoring, recoveryMessage == nil, !shuttingDown, !Task.isCancelled else { return nil }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        do {
            let result = try await service.execute(.createRemoteWindow(name: host.name, hostID: host.id))
            guard let id = result.createdWindowID, let window = result.snapshot.windows.first(where: { $0.id == id }),
                let tab = result.snapshot.tabs[window.activeTabID], let pane = result.snapshot.panes[tab.activePaneID]
            else { return nil }
            attachTerminal(pane)
            publish(result.snapshot)
            await start(paneID: pane.id)
            return id
        } catch { errorMessage = "The remote workspace could not be created."; return nil }
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
    func startRemote(paneID: UUID, terminal: NativeTerminal, request: SessionLaunchRequest, hostID: UUID, directory: String?) async {
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
        let wasConnected = remoteLinks[hostID] == .connected
        if !wasConnected { remoteLinks[hostID] = .connecting }
        let linked = await remoteHosts.workspaceLink(host, interactive: true)
        guard case .success(let link) = linked, let connection = link.connection else {
            let message = linked.failure.map(RemoteHostsModel.message(for:)) ?? "The connection failed."
            remoteLinks[hostID] = .disconnected(message)
            return await refuse("Could not connect to \(host.name). \(message)")
        }
        remoteLinks[hostID] = .connected
        // FR-RW09: the host is reachable again, so its other panes resume or re-attach now rather than waiting for Reconnect.
        if !wasConnected { Task { await reconnectRemote(hostID: hostID, interactive: false) } }
        guard terminals[paneID] === terminal, !isClosing(paneID: paneID), !shuttingDown, !Task.isCancelled else {
            return await refuse("Session launch was cancelled.")
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
        case .failed(let failure): remoteLinks[host] = .disconnected(RemoteHostsModel.message(for: failure))
        case .closed, .idle: if remoteLinks[host] == .connected { remoteLinks[host] = .disconnected(nil) }
        }
    }

    /// At launch: every host with a remote workspace is tried without prompting, and its panes re-attach (FR-RW09).
    func reattachRemoteSessions() async {
        for host in Set(snapshot.windows.compactMap(\.remoteHostID)) where !shuttingDown {
            await remoteReconnector.attempt(host, interactive: false)
        }
    }

    /// A window bound to the host, a project setup running there, or a hangup still to send (a setup cancelled while
    /// disconnected): each needs the link back after a drop (FR-RW07).
    public func hasRemoteWorkspace(_ hostID: UUID) -> Bool {
        snapshot.windows.contains { $0.remoteHostID == hostID } || projectLaunch?.terminal?.remoteTransport?.hostID == hostID
            || pendingRemoteHangups[hostID]?.isEmpty == false
    }

    /// The host's terminals: its panes, and a project setup running there (FR-PL07), which is in no pane.
    private func remoteTerminals(_ hostID: UUID) -> [NativeTerminal] {
        (Array(terminals.values) + [projectLaunch?.terminal].compactMap { $0 }).filter { $0.remoteTransport?.hostID == hostID }
    }

    /// **Reconnect…** (`interactive`: ssh may ask in the console) or **Retry Now**, through the reconnector, which
    /// schedules the next automatic attempt if this one fails for a reason a retry can fix (FR-RW07).
    public func reconnectRemote(hostID: UUID, interactive: Bool = true) async {
        await remoteReconnector.attempt(hostID, interactive: interactive)
    }

    /// Connects to `hostID` again: live panes resume where they stopped, restored panes adopt their sessions, and
    /// sessions closed while it was unreachable are hung up. Returns why it failed, or nil.
    func connectRemote(hostID: UUID, interactive: Bool) async -> RemoteHostLink.Failure? {
        // One at a time per host: two passes would attach the same sessions twice.
        guard let remoteHosts, !shuttingDown, remoteReconnecting.insert(hostID).inserted else { return .cancelled }
        defer { remoteReconnecting.remove(hostID) }
        guard let host = await resolveHost?(hostID) else {
            remoteLinks[hostID] = .disconnected("This saved host no longer exists.")
            return .cancelled
        }
        // Quit while the host was being resolved: no link is opened after the others were closed.
        guard !shuttingDown else { return .cancelled }
        remoteLinks[hostID] = .connecting
        let linked = await remoteHosts.workspaceLink(host, interactive: interactive)
        guard case .success(let link) = linked, let connection = link.connection else {
            let failure = linked.failure ?? .lost
            remoteLinks[hostID] = .disconnected(RemoteHostsModel.message(for: failure))
            return failure
        }
        remoteLinks[hostID] = .connected
        let hungUp = pendingRemoteHangups.removeValue(forKey: hostID) ?? []
        for id in hungUp { connection.post(.signal(sessionID: id, signal: SIGHUP)) }
        for terminal in remoteTerminals(hostID) {
            guard let transport = terminal.remoteTransport, let size = terminalSize(terminal) else { continue }
            _ = await transport.resume(on: connection, size: size)
        }
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
                sessionID: record.sessionID, processID: attachment.record.processID, exitCode: nil, nonce: attachment.nonce, replay: replay, transport: transport)
            if !terminal.adopt(adoption) { enqueue(.recordSessionExit(sessionID: record.sessionID, code: nil)) }
        }
        remoteOrphansAsked.formUnion(orphans)
        if !orphans.isEmpty, confirmStopOrphans(orphans.count) {
            for id in orphans { connection.post(.signal(sessionID: id, signal: SIGHUP)) }
        }
    }
}
