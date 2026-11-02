import AppKit
import Foundation
import TrellisBroker
import TrellisCore
import TrellisTerminal

/// The remote helper on each saved host (FR-RW17): check, install or update, and remove it over a `RemoteHostLink`, record
/// what a probe saw in `remote-hosts.json`, and show ssh's console whenever ssh writes to it.
@MainActor
public final class RemoteHostsModel: ObservableObject {
    public enum Activity: Equatable, Sendable { case checking, installing, removing }

    /// A host's ssh terminal, shown in a sheet so prompts are answered where ssh asks them.
    public struct Console: Identifiable {
        public let id: UUID
        public let hostName: String
        public let terminal: NativeTerminal
    }

    @Published public private(set) var preferences: [UUID: RemoteHostPreferences] = [:]
    @Published public private(set) var activity: [UUID: Activity] = [:]
    @Published public private(set) var messages: [UUID: String] = [:]
    @Published public var console: Console?

    public let settings: RemoteHostSettings
    public var catalog: RemoteArtifactCatalog
    /// This state directory's client ID (FR-RW13); nil when it couldn't be created, which disables the actions.
    public var clientID: String?
    public var sshExecutable = "/usr/bin/ssh"
    public var environment: () -> [String: String] = { ProcessInfo.processInfo.environment }
    public var askpass: AskpassBroker?
    public var savedPassword: (@Sendable (UUID, UInt64) async -> Data?)?
    public var now: () -> Date = Date.init
    /// Install (`false`) or update (`true`); production shows an alert naming the host, platform, path and size.
    public var confirmInstall: (SavedHost, RemoteProbe, RemoteArtifact, Bool) async -> Bool = { _, _, _, _ in false }
    public var confirmRemove: (SavedHost) -> Bool = { _ in false }
    /// Running sessions would lose their helper; production asks to stop them.
    public var confirmStopSessions: (SavedHost, Int) -> Bool = { _, _ in false }
    /// The link of each host's running host-library action, which Cancel closes.
    private var actionLinks: [UUID: RemoteHostLink] = [:]
    private var cancelled: Set<UUID> = []
    /// A workspace link still connecting, closed at quit with the connected ones.
    private var connectingLinks: [UUID: RemoteHostLink] = [:]
    /// The connected link each host's remote workspaces share (FR-RW03).
    private var workspaceLinks: [UUID: RemoteHostLink] = [:]
    private var connecting: [UUID: Task<Result<RemoteHostLink, RemoteHostLink.Failure>, Never>] = [:]
    /// A workspace link's state changed; the sidebar shows it (FR-RW07, FR-RW16).
    public var onWorkspaceLinkChanged: ((UUID, RemoteHostLink.State) -> Void)?

    public init(settings: RemoteHostSettings, catalog: RemoteArtifactCatalog, clientID: String?) {
        self.settings = settings; self.catalog = catalog; self.clientID = clientID
        confirmInstall = { [weak self] host, probe, artifact, update in self?.showInstallAlert(host, probe, artifact, update) ?? false }
        confirmRemove = { [weak self] host in self?.showRemoveAlert(host) ?? false }
        confirmStopSessions = { [weak self] host, count in self?.showStopSessionsAlert(host, count) ?? false }
    }

    /// `hosts` nil: the host library couldn't be read, so no entry is known to be stale and none is dropped.
    public func load(hosts: [SavedHost]?) async {
        if let hosts { await settings.retain(Set(hosts.map(\.id))) }
        preferences = await settings.all()
    }

    public func preferences(_ host: SavedHost) -> RemoteHostPreferences { preferences[host.id] ?? .init() }
    public var isAvailable: Bool { clientID != nil }

    public func setAutoInstall(_ host: SavedHost, _ enabled: Bool) async {
        preferences[host.id] = await settings.update(host.id) { $0.autoInstall = enabled }
    }

    public func check(_ host: SavedHost) async {
        await perform(host, .checking) { await self.connect(host, .check, install: .never) }
    }

    /// Installs this build's helper, or updates an older one, after confirmation (FR-RW02).
    public func install(_ host: SavedHost) async {
        await perform(host, .installing) { await self.connect(host, .install, install: .ask) }
    }

    /// Refused while this Mac's sessions run there, unless the user stops them first, and whenever they can't be counted.
    public func remove(_ host: SavedHost) async {
        guard confirmRemove(host) else { return }
        await perform(host, .removing) {
            // The shared workspace link lists them: a bridge of its own would take the broker's client slot from it.
            var link: RemoteHostLink?
            var connection = self.workspaceConnection(host.id)
            if connection == nil {
                let bridge = self.makeLink(host)
                switch await self.run(bridge, host, .bridge, install: .never) {
                case .success: link = bridge; connection = bridge.connection
                case .failure(.cancelled): return Self.message(for: .cancelled)
                // No helper at all, so no broker of this Mac's runs there.
                case .failure where bridge.probe?.installed.isEmpty == true: break
                case .failure(let failure): return "The helper was kept: its running sessions couldn’t be checked. " + Self.message(for: failure)
                }
            }
            if let connection {
                let running: Int? =
                    if case .sessions(let records)? = try? await connection.request(.list) { records.filter(\.running).count } else { nil }
                // Cancelled while listing: cancelling never changes the host.
                if link?.state == .closed || self.cancelled.contains(host.id) { link?.close(); return Self.message(for: .cancelled) }
                guard let running else { link?.close(); return "The helper was kept: its running sessions couldn’t be checked." }
                if running > 0 {
                    guard self.confirmStopSessions(host, running) else { link?.close(); return "The helper was kept, with its \(running) running session(s)." }
                    connection.sendStopAll()
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
            link?.close()
            if self.cancelled.contains(host.id) { return Self.message(for: .cancelled) }
            return await self.connect(host, .remove, install: .never)
        }
    }

    private func perform(_ host: SavedHost, _ kind: Activity, _ work: @escaping () async -> String?) async {
        guard activity[host.id] == nil, isAvailable else { return }
        activity[host.id] = kind
        messages[host.id] = nil
        cancelled.remove(host.id)
        let message = await work()
        activity[host.id] = nil
        actionLinks[host.id] = nil
        cancelled.remove(host.id)
        messages[host.id] = message
    }

    /// Runs one link for `purpose`, records what its probe saw, and returns the message to show (nil on plain success).
    /// The link remote workspace sessions on `host` share: reused while connected, otherwise opened, once at a time.
    /// `interactive` lets ssh ask in the console; an automatic attempt never prompts (`BatchMode`). The helper is
    /// installed without asking only when the host's auto-install is on; otherwise interactively after confirmation.
    public func workspaceLink(_ host: SavedHost, interactive: Bool) async -> Result<RemoteHostLink, RemoteHostLink.Failure> {
        if let link = workspaceLinks[host.id], link.state == .connected { return .success(link) }
        if let pending = connecting[host.id] { return await pending.value }
        guard isAvailable else { return .failure(.cancelled) }
        let task = Task { [self] () -> Result<RemoteHostLink, RemoteHostLink.Failure> in
            let link = self.makeLink(host, batch: !interactive)
            let policy: RemoteHostLink.InstallPolicy = self.preferences(host).autoInstall ? .always : (interactive ? .ask : .never)
            let result = await self.run(link, host, .bridge, install: policy, workspace: true)
            guard case .success = result else {
                await self.record(host, link, .bridge, result)
                return .failure(result.failure ?? .lost)
            }
            // Watched before the status is saved: a drop while that waits is reported, never handed out as connected.
            self.workspaceLinks[host.id] = link
            link.onStateChanged = { [weak self, weak link] state in
                guard let self, let link, self.workspaceLinks[host.id] === link else { return }
                if state != .connected { self.workspaceLinks[host.id] = nil }
                self.onWorkspaceLinkChanged?(host.id, state)
            }
            await self.record(host, link, .bridge, result)
            guard link.state == .connected else { return .failure(.lost) }
            self.onWorkspaceLinkChanged?(host.id, .connected)
            return .success(link)
        }
        connecting[host.id] = task
        defer { connecting[host.id] = nil }
        return await task.value
    }

    public func workspaceLinkState(_ hostID: UUID) -> RemoteHostLink.State? { workspaceLinks[hostID]?.state }

    /// Every host with a connected workspace link, for Settings → Sessions.
    public var connectedWorkspaceHosts: [UUID] { workspaceLinks.filter { $0.value.state == .connected }.map(\.key) }

    /// The connected link's protocol connection to `hostID`, without connecting.
    public func workspaceConnection(_ hostID: UUID) -> BrokerConnection? {
        workspaceLinks[hostID].flatMap { $0.state == .connected ? $0.connection : nil }
    }

    /// After wake or a network change: every connected link pings now (FR-RW07).
    public func checkWorkspaceLinks() { workspaceLinks.values.forEach { $0.checkNow() } }

    /// Quit or window close: every workspace link ends; nothing is sent to the hosts' sessions (FR-RW06).
    public func closeWorkspaceLinks() {
        let open = workspaceLinks.values
        workspaceLinks = [:]
        for link in open { link.onStateChanged = nil; link.close() }
        // A link still connecting (an automatic attempt) ends too, so none is left open after quit.
        connectingLinks.values.forEach { $0.close() }
    }

    private func record(_ host: SavedHost, _ link: RemoteHostLink, _ purpose: RemoteHostLink.Purpose, _ result: Result<RemoteProbe, RemoteHostLink.Failure>) async {
        guard let probe = link.probe else { return }
        var record = RemoteHelperRecord(probe: probe, catalog: catalog, checkedAt: now())
        if purpose == .remove, case .success = result { record.state = .missing }
        let observed = record
        preferences[host.id] = await settings.update(host.id) { $0.helper = observed }
    }

    private func connect(_ host: SavedHost, _ purpose: RemoteHostLink.Purpose, install: RemoteHostLink.InstallPolicy) async -> String? {
        let link = makeLink(host)
        let result = await run(link, host, purpose, install: install)
        await record(host, link, purpose, result)
        switch result {
        case .success:
            return switch purpose {
            case .install: "The helper is installed."
            case .remove: "The helper was removed."
            default: nil
            }
        case .failure(let failure): return Self.message(for: failure)
        }
    }

    private func makeLink(_ host: SavedHost, batch: Bool = false) -> RemoteHostLink {
        let request = RemoteHostLink.Request(
            sshExecutable: sshExecutable, options: host.sshOptions, destination: host.destination, environment: environment(), clientID: clientID ?? "",
            batch: batch)
        return RemoteHostLink(request: request, catalog: catalog)
    }

    /// `workspace`: the link remote workspaces will share; otherwise a host-library action's, until the action ends.
    private func run(_ link: RemoteHostLink, _ host: SavedHost, _ purpose: RemoteHostLink.Purpose, install: RemoteHostLink.InstallPolicy, workspace: Bool = false)
        async -> Result<RemoteProbe, RemoteHostLink.Failure>
    {
        if workspace { connectingLinks[host.id] = link } else { actionLinks[host.id] = link }
        link.confirmInstall = { [weak self] probe, artifact in
            await self?.confirmInstall(host, probe, artifact, !probe.installed.isEmpty) ?? false
        }
        link.onConsoleOutput = { [weak self, weak link] in
            // An automatic attempt's message reaches the sidebar; it never takes over the console another host may be using.
            guard let self, let link, !link.request.batch, self.console?.terminal !== link.console else { return }
            self.console = Console(id: host.id, hostName: host.name, terminal: link.console)
        }
        // A saved password answers ssh's password prompt once, through askpass (FR-H08); nothing else is answered.
        var registration: AskpassBroker.Registration?
        // Never for an automatic attempt: a saved password is not retried on its own (INT-05).
        if host.savedPassword != nil, !link.request.batch, let askpass, let savedPassword {
            let id = host.id, revision = host.connectionRevision
            registration = askpass.register(parent: { [weak link] in await MainActor.run { link?.processID } }, answer: { await savedPassword(id, revision) })
        }
        if let registration, let askpass {
            link.environmentOverrides = registration.environment(helper: askpass.helperPath)
        }
        let result = await link.run(purpose, install: install)
        if let registration { askpass?.unregister(registration) }
        if workspace, connectingLinks[host.id] === link { connectingLinks[host.id] = nil }
        return result
    }

    /// Stops a running action's ssh; the host is never changed by cancelling.
    public func cancel(_ host: SavedHost) {
        guard activity[host.id] != nil else { return }
        cancelled.insert(host.id)
        actionLinks[host.id]?.close()
    }

    public static func message(for failure: RemoteHostLink.Failure) -> String {
        switch failure {
        case .spawn(let code): "ssh could not be started (\(String(cString: strerror(code))))."
        case .exited(let code): "ssh ended\(code.map { " (exit \($0))" } ?? "") before the helper answered. The connection console shows ssh’s message."
        case .unsupported(let platform): "Trellis has no helper for \(platform)."
        case .noChecksumTool: "The host has no sha256sum, shasum or openssl, so the helper can’t be verified there. Nothing was installed."
        case .artifactUnavailable(let platform): "This build of Trellis doesn’t include the helper for \(platform)."
        case .declined: "Nothing was installed."
        case .remote("DIGEST"): "The upload didn’t match its SHA-256 on the host, so it was deleted. Nothing was installed."
        case .remote("MKDIR"): "~/.trellis could not be created on the host. Check that your home folder there is writable."
        case .remote("MISSING"): "The helper is missing on the host. Install it again."
        case .remote("GZIP"): "The host has no gzip, which the helper upload needs. Nothing was installed."
        case .remote(let code): "The host refused the request (\(code))."
        case .incompatible: "The helper on the host speaks another protocol version. Update it."
        case .cancelled: "Cancelled."
        case .lost: "The connection was lost."
        case .unreachable(let reason): reason.isEmpty ? "The host can’t be reached." : "The host can’t be reached (\(reason))."
        case .needsInput(let reason): "Reconnecting needs you: \(reason)"
        }
    }

    private func showInstallAlert(_ host: SavedHost, _ probe: RemoteProbe, _ artifact: RemoteArtifact, _ update: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = update ? "Update the Trellis helper on “\(host.name)”?" : "Install the Trellis helper on “\(host.name)”?"
        let size = ByteCountFormatter.string(fromByteCount: Int64(artifact.fileSize), countStyle: .file)
        alert.informativeText =
            "Trellis copies its helper for \(probe.displayName) (\(size)) to ~/.trellis/remote/\(artifact.directory) on \(host.destination), checks its SHA-256 there, and uses it to keep your sessions running. It needs no administrator rights and changes nothing outside ~/.trellis."
        alert.addButton(withTitle: update ? "Update" : "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showRemoveAlert(_ host: SavedHost) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove the Trellis helper from “\(host.name)”?"
        alert.informativeText = "Deletes ~/.trellis/remote and ~/.trellis/run on \(host.destination), for every Mac that uses this host. Nothing else is changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showStopSessionsAlert(_ host: SavedHost, _ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(count) session(s) are still running on “\(host.name)”."
        alert.informativeText = "Removing the helper stops them first. Their output and running commands end."
        alert.addButton(withTitle: "Stop and Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension Result {
    var failure: Failure? { if case .failure(let failure) = self { failure } else { nil } }
}
