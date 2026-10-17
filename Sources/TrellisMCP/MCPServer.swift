import Foundation
import TrellisControl
import TrellisCore

/// Owns the MCP listener and endpoint for the current Remote Control settings
/// (FR-RC01–FR-RC04). Applying settings always stops the old listener first,
/// so at most one address is ever bound.
public final class MCPServer: @unchecked Sendable {
    private let handler: AuthorizingControlHandler
    private let serverVersion: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var listener: MCPListener?
    private var endpoint: MCPEndpoint?
    private var current: RemoteControlStatus = .stopped

    public init(handler: AuthorizingControlHandler, serverVersion: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.handler = handler; self.serverVersion = serverVersion; self.now = now
    }

    public var status: RemoteControlStatus { lock.withLock { current } }

    /// Stops any running listener, then starts one when enabled. Returns the new status.
    @discardableResult
    public func apply(_ settings: RemoteControlSettings) -> RemoteControlStatus {
        stop()
        guard settings.mcpEnabled else { return .stopped }
        guard settings.isValid else { return set(.failed(reason: MCPListenerError.invalidAddress.message(port: settings.port))) }
        let endpoint = MCPEndpoint(handler: handler, serverVersion: serverVersion, loopbackOnly: settings.isLoopback, now: now)
        let listener = MCPListener { request in await endpoint.handle(request) }
        do {
            let port = try listener.start(address: settings.bindAddress, port: settings.port)
            lock.withLock {
                self.listener = listener; self.endpoint = endpoint
            }
            return set(.running(url: RemoteControlSettings.endpointURL(address: settings.bindAddress, port: port)))
        } catch {
            return set(.failed(reason: error.message(port: settings.port)))
        }
    }

    public func stop() {
        let (listener, endpoint) = lock.withLock { () -> (MCPListener?, MCPEndpoint?) in
            defer { self.listener = nil; self.endpoint = nil; current = .stopped }
            return (self.listener, self.endpoint)
        }
        listener?.stop()
        if let endpoint { Task { await endpoint.closeAll() } }
    }

    /// Revocation ends the grant's MCP sessions immediately.
    public func closeSessions(grantID: UUID) async {
        await lock.withLock { endpoint }?.closeSessions(grantID: grantID)
    }

    private func set(_ status: RemoteControlStatus) -> RemoteControlStatus {
        lock.withLock { current = status }
        return status
    }
}
