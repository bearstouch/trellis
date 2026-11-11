import Foundation
import TrellisCore

/// Keeps Trellis's `tailscale serve` entry and the endpoint's tailnet access in line
/// with the settings (FR-RC06, FR-RC07, FR-RC09). Operations run one at a time, so
/// two quick Applies never leave an entry nobody tracks.
public actor TailscaleSharing {
    /// Re-checked this often while shared, and sooner while waiting for Tailscale.
    public static let sharedInterval: TimeInterval = 60
    public static let waitingInterval: TimeInterval = 10

    private let controller: TailscaleController
    private let server: MCPServer
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onState: @Sendable (TailscaleShareState) -> Void
    private var settings = RemoteControlSettings()
    /// The entry this app run published: removed when sharing stops or the app quits.
    private var published: (host: String, port: UInt16, target: String)?
    private var state: TailscaleShareState = .off
    private var queue: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var generation = 0

    public init(
        controller: TailscaleController, server: MCPServer, sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        onState: @escaping @Sendable (TailscaleShareState) -> Void
    ) {
        self.controller = controller; self.server = server; self.sleep = sleep; self.onState = onState
    }

    public var currentState: TailscaleShareState { state }

    /// Call after the MCP server applied `settings` (it starts with no tailnet access).
    public func apply(_ settings: RemoteControlSettings) async {
        await serially { await $0.perform(settings) }
    }

    /// Checks Tailscale now and repairs the entry if it went missing.
    public func reconcile() async {
        await serially { await $0.check() }
    }

    /// Removes Trellis's entry, so nothing else that later takes the port is reachable from the tailnet.
    public func shutdown() async {
        await serially { sharing in
            await sharing.stopLoop()
            await sharing.turnOff()
            await sharing.withdraw()
            await sharing.publish(.off)
        }
    }

    // MARK: - Steps

    private func serially(_ body: @escaping @Sendable (TailscaleSharing) async -> Void) async {
        let previous = queue
        let task = Task {
            await previous?.value; await body(self)
        }
        queue = task
        await task.value
    }

    private func perform(_ new: RemoteControlSettings) async {
        stopLoop()
        settings = new
        // A check that was in flight while the server restarted may have handed the new
        // endpoint the old access; nothing is admitted until this check confirms the entry.
        await server.setTailnetAccess(nil)
        if let published, !(new.sharesOverTailscale && published.port == new.tailscalePort && published.target == new.serveTarget) { await withdraw() }
        guard new.sharesOverTailscale else {
            await server.setTailnetAccess(nil)
            publish(.off)
            return
        }
        publish(.starting)
        await check()
        startLoop()
    }

    private func check() async {
        guard settings.sharesOverTailscale else { return }
        let status: TailscaleStatus
        switch await controller.status() {
        case .failure(let error):
            // A slow or odd CLI answer keeps working clients; the next check tries again.
            publish(.failed(.tailscale(error)))
            return
        case .success(let value): status = value
        }
        switch status.backend {
        case .notInstalled:
            await server.setTailnetAccess(nil)
            publish(.failed(.notConnected(.notInstalled)))
            return
        case .stopped, .needsLogin:
            publish(.waiting)
            return
        case .connected: break
        }
        let port = settings.tailscalePort, target = settings.serveTarget
        do throws(TailscaleShareError) {
            let url = try await controller.share(status: status, port: port, target: target)
            if let host = status.dnsName { published = (host, port, target) }
            await server.setTailnetAccess(TailnetAccess(hostName: status.dnsName ?? "", port: port, allowedClients: allowedClients(status)))
            publish(.shared(url: url))
        } catch {
            if case .funnelOn = error { published = nil }
            // Like an unreadable status, a slow or failed CLI call keeps a confirmed entry's clients.
            if case .tailscale = error, published?.host == status.dnsName, published?.port == port, published?.target == target {
            } else {
                await server.setTailnetAccess(nil)
            }
            publish(.failed(error))
        }
    }

    /// After shutdown a loop iteration that was already past its checks finds nothing to share.
    private func turnOff() { settings = RemoteControlSettings() }

    /// The chosen devices' current addresses, or the saved ones while a device isn't listed.
    private func allowedClients(_ status: TailscaleStatus) -> [IPAddressLiteral]? {
        guard !settings.allowedDevices.isEmpty else { return nil }
        let current = Dictionary(status.peers.map { ($0.id, $0.addresses) }) { first, _ in first }
        return settings.allowedDevices.flatMap { current[$0.id] ?? $0.addresses }.compactMap(IPAddressLiteral.init)
    }

    private func withdraw() async {
        guard let entry = published else { return }
        await controller.unshare(host: entry.host, port: entry.port, target: entry.target)
        published = nil
    }

    private func startLoop() {
        generation += 1
        let mine = generation
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let interval = await self.nextInterval(mine) else { return }
                await self.sleep(interval)
                guard !Task.isCancelled else { return }
                await self.reconcile()
            }
        }
    }

    private func nextInterval(_ mine: Int) -> TimeInterval? {
        guard mine == generation, settings.sharesOverTailscale else { return nil }
        if case .shared = state { return Self.sharedInterval }
        return Self.waitingInterval
    }

    private func stopLoop() {
        generation += 1
        loop?.cancel(); loop = nil
    }

    private func publish(_ new: TailscaleShareState) {
        guard new != state else { return }
        state = new
        onState(new)
    }
}
