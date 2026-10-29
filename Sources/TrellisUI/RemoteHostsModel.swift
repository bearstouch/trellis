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
    private var links: [UUID: RemoteHostLink] = [:]

    public init(settings: RemoteHostSettings, catalog: RemoteArtifactCatalog, clientID: String?) {
        self.settings = settings; self.catalog = catalog; self.clientID = clientID
        confirmInstall = { [weak self] host, probe, artifact, update in self?.showInstallAlert(host, probe, artifact, update) ?? false }
        confirmRemove = { [weak self] host in self?.showRemoveAlert(host) ?? false }
        confirmStopSessions = { [weak self] host, count in self?.showStopSessionsAlert(host, count) ?? false }
    }

    public func load(hosts: [SavedHost]) async {
        await settings.retain(Set(hosts.map(\.id)))
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

    /// Refused while this Mac's sessions run there, unless the user stops them first.
    public func remove(_ host: SavedHost) async {
        guard confirmRemove(host) else { return }
        await perform(host, .removing) {
            if self.preferences(host).helper?.state == .current {
                let link = self.makeLink(host)
                let bridged = await self.run(link, host, .bridge, install: .never)
                if case .success = bridged, let connection = link.connection {
                    let running =
                        (try? await connection.request(.list)).flatMap { message -> Int? in
                            if case .sessions(let records) = message { records.filter(\.running).count } else { nil }
                        } ?? 0
                    // Cancelled while listing: the empty count above is not an answer, and cancelling never changes the host.
                    if link.state == .closed { return Self.message(for: .cancelled) }
                    if running > 0 {
                        guard self.confirmStopSessions(host, running) else { link.close(); return "The helper was kept, with its \(running) running session(s)." }
                        connection.sendStopAll()
                        try? await Task.sleep(for: .milliseconds(600))
                    }
                }
                link.close()
                if bridged == .failure(.cancelled) { return Self.message(for: .cancelled) }
            }
            return await self.connect(host, .remove, install: .never)
        }
    }

    private func perform(_ host: SavedHost, _ kind: Activity, _ work: @escaping () async -> String?) async {
        guard activity[host.id] == nil, isAvailable else { return }
        activity[host.id] = kind
        messages[host.id] = nil
        let message = await work()
        activity[host.id] = nil
        messages[host.id] = message
    }

    /// Runs one link for `purpose`, records what its probe saw, and returns the message to show (nil on plain success).
    private func connect(_ host: SavedHost, _ purpose: RemoteHostLink.Purpose, install: RemoteHostLink.InstallPolicy) async -> String? {
        let link = makeLink(host)
        let result = await run(link, host, purpose, install: install)
        if let probe = link.probe {
            var record = RemoteHelperRecord(probe: probe, catalog: catalog, checkedAt: now())
            if purpose == .remove, case .success = result { record.state = .missing }
            let observed = record
            preferences[host.id] = await settings.update(host.id) { $0.helper = observed }
        }
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

    private func makeLink(_ host: SavedHost) -> RemoteHostLink {
        let request = RemoteHostLink.Request(
            sshExecutable: sshExecutable, options: host.sshOptions, destination: host.destination, environment: environment(), clientID: clientID ?? "")
        return RemoteHostLink(request: request, catalog: catalog)
    }

    private func run(_ link: RemoteHostLink, _ host: SavedHost, _ purpose: RemoteHostLink.Purpose, install: RemoteHostLink.InstallPolicy) async -> Result<
        RemoteProbe, RemoteHostLink.Failure
    > {
        links[host.id] = link
        link.confirmInstall = { [weak self] probe, artifact in
            await self?.confirmInstall(host, probe, artifact, !probe.installed.isEmpty) ?? false
        }
        link.onConsoleOutput = { [weak self, weak link] in
            guard let self, let link, self.console?.terminal !== link.console else { return }
            self.console = Console(id: host.id, hostName: host.name, terminal: link.console)
        }
        // A saved password answers ssh's password prompt once, through askpass (FR-H08); nothing else is answered.
        var registration: AskpassBroker.Registration?
        if host.savedPassword != nil, let askpass, let savedPassword {
            let id = host.id, revision = host.connectionRevision
            registration = askpass.register(parent: { [weak link] in await MainActor.run { link?.processID } }, answer: { await savedPassword(id, revision) })
        }
        if let registration, let askpass {
            link.environmentOverrides = registration.environment(helper: askpass.helperPath)
        }
        let result = await link.run(purpose, install: install)
        if let registration { askpass?.unregister(registration) }
        if links[host.id] === link, purpose != .bridge { links[host.id] = nil }
        return result
    }

    /// Stops a running action's ssh; the host is never changed by cancelling.
    public func cancel(_ host: SavedHost) { links[host.id]?.close() }

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
