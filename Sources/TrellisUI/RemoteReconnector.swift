import AppKit
import Network
import TrellisCore
import TrellisTerminal

/// Automatic reconnects for remote workspaces (FR-RW07): after a lost link, attempts without prompting (`BatchMode`)
/// back off from 1 s to 60 s with jitter and pause while the Mac is offline; wake and network changes check links at
/// once. An attempt that needs the person stops them until **Reconnect…**, so a credential is never retried in a loop.
@MainActor
public final class RemoteReconnector {
    public var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    public var random: () -> Double = { Double.random(in: 0...1) }
    public var now: () -> Date = Date.init
    public private(set) var online = true
    weak var model: AppWorkspaceModel?
    private var attempts: [UUID: Int] = [:]
    private var waits: [UUID: Task<Void, Never>] = [:]
    private var running: Set<UUID> = []
    private var monitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?

    /// Attempts made since the link was last up.
    public func attemptCount(_ host: UUID) -> Int { attempts[host] ?? 0 }

    /// A link to `host` went down: the next attempt waits for the backoff. During an attempt, that attempt's outcome decides.
    func lost(_ host: UUID) {
        guard !running.contains(host) else { return }
        schedule(host)
    }

    /// One attempt now. `interactive` (Reconnect…) lets ssh ask in the console; automatic ones never do.
    public func attempt(_ host: UUID, interactive: Bool) async {
        guard let model, !model.shuttingDown, !running.contains(host) else { return }
        guard model.hasRemoteWorkspace(host) else { forget(host); return }
        waits.removeValue(forKey: host)?.cancel()
        running.insert(host)
        let failure = await model.connectRemote(hostID: host, interactive: interactive)
        running.remove(host)
        guard let failure else {
            forget(host)
            // The new link can drop while panes re-attach; that loss was left to this attempt (`lost`).
            if model.remoteHosts?.workspaceLinkState(host) != .connected { schedule(host) }
            return
        }
        handle(host, failure)
    }

    private func handle(_ host: UUID, _ failure: RemoteHostLink.Failure) {
        guard let model, !model.shuttingDown else { return }
        switch failure {
        case .needsInput(let reason): waits.removeValue(forKey: host)?.cancel(); model.remoteLinks[host] = .needsInput(reason)
        case .unreachable, .lost, .exited, .spawn: schedule(host)
        case .cancelled: break
        // Nothing a retry can change: a missing helper, an unsupported host, a refused install.
        case .declined, .unsupported, .noChecksumTool, .artifactUnavailable, .remote, .incompatible:
            model.remoteLinks[host] = .disconnected(RemoteHostsModel.message(for: failure))
        }
    }

    private func schedule(_ host: UUID) {
        guard let model, !model.shuttingDown, model.hasRemoteWorkspace(host) else { return }
        waits.removeValue(forKey: host)?.cancel()
        guard online else { model.remoteLinks[host] = .offline; return }
        let attempt = (attempts[host] ?? 0) + 1
        attempts[host] = attempt
        let delay = RemoteBackoff.delay(attempt: attempt, random: random())
        model.remoteLinks[host] = .reconnecting(attempt: attempt, at: now().addingTimeInterval(delay))
        let sleep = sleep
        waits[host] = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // Ours, so `attempt` doesn't cancel the task it runs in.
            waits[host] = nil
            await self.attempt(host, interactive: false)
        }
    }

    /// **Retry Now**: an automatic attempt at once, keeping the count.
    public func retryNow(_ host: UUID) { Task { await attempt(host, interactive: false) } }

    /// Hosts waiting for an automatic attempt, or paused offline (not those that need the person).
    private var pending: [UUID] {
        (model?.remoteLinks ?? [:]).compactMap { host, link in
            switch link {
            case .reconnecting, .offline: host
            default: nil
            }
        }
    }

    /// Every path update: a change of interface can strand a connection even while the Mac stays online.
    public func networkChanged(online: Bool) {
        model?.remoteHosts?.checkWorkspaceLinks()
        guard online != self.online else { return }
        self.online = online
        if online {
            for host in pending { retryNow(host) }
        } else {
            for host in pending {
                waits.removeValue(forKey: host)?.cancel()
                model?.remoteLinks[host] = .offline
            }
        }
    }

    /// After sleep, links may be dead without having noticed: check them, and retry waiting hosts now.
    public func didWake() {
        model?.remoteHosts?.checkWorkspaceLinks()
        if online { for host in pending { retryNow(host) } }
    }

    func forget(_ host: UUID) {
        attempts[host] = nil
        waits.removeValue(forKey: host)?.cancel()
    }

    func cancelAll() {
        waits.values.forEach { $0.cancel() }
        waits = [:]
        attempts = [:]
    }

    /// The app's wake notification and network path; tests call `didWake` and `networkChanged` instead.
    public func startSystemMonitoring() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.bearstouch.trellis.remote.network"))
        self.monitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    isolated deinit {
        monitor?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        waits.values.forEach { $0.cancel() }
    }
}
