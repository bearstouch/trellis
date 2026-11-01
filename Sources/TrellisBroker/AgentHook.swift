#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import Dispatch
#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif
import TrellisPOSIX

/// The pane-scoped channel an agent's own hooks report through (FR-AG08). A hook runs `trellis-broker agent-hook <event>`,
/// which sends one datagram, `TRELLIS-AGENT-1 <nonce> <event>`, to the socket named in the session's environment. Only
/// a fixed event name crosses: the agent's hook payload (prompts, tool arguments) is never read past its pipe, so it is
/// never forwarded, logged or kept. The nonce maps to one session and carries no other capability.
public enum AgentHook {
    public static let events: Set<String> = ["start", "working", "needs-input", "done", "error", "end"]
    public static let prefix = "TRELLIS-AGENT-1"
    public static let datagramLimit = 256
    /// How much of a hook's stdin is drained (and discarded) so the agent never blocks writing its payload.
    static let drainLimit = 4 * 1_048_576

    public static func isNonce(_ value: String) -> Bool {
        (16...128).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if trellis_random_bytes(&bytes, bytes.count) != 0 {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = generator.next() }
        }
        let digits = Array("0123456789abcdef")
        return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0f)]] })
    }

    public static func encode(nonce: String, event: String) -> [UInt8]? {
        guard isNonce(nonce), events.contains(event) else { return nil }
        return Array("\(prefix) \(nonce) \(event)".utf8)
    }

    public static func decode(_ bytes: [UInt8]) -> (nonce: String, event: String)? {
        guard bytes.count <= datagramLimit, bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
        let parts = String(decoding: bytes, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix, isNonce(parts[1]), events.contains(parts[2]) else { return nil }
        return (parts[1], parts[2])
    }

    /// `trellis-broker agent-hook <event>`. Always exits 0 and prints nothing: a hook must never block, fail or steer
    /// the agent (Claude Code treats exit 2 as "block"), and outside a Trellis agent session it does nothing at all.
    public static func main(arguments: [String], environment: [String: String]) -> Int32 {
        drainStandardInput()
        guard arguments.count >= 3, let socket = environment[BrokerProtocol.agentSocketVariable], let nonce = environment[BrokerProtocol.agentNonceVariable],
            let datagram = encode(nonce: nonce, event: arguments[2])
        else { return 0 }
        send(datagram, to: socket)
        return 0
    }

    @discardableResult
    public static func send(_ datagram: [UInt8], to path: String) -> Bool {
        guard path.hasPrefix("/"), BrokerFiles.isOwnedSocket(path), var address = BrokerFiles.address(path) else { return false }
        let fd = trellis_unix_datagram_socket()
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let sent = datagram.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
        return sent == datagram.count
    }

    /// Claude Code writes the hook's JSON to a pipe and may wait for it to be read; a terminal (Codex runs `notify`
    /// with the agent's own stdin) is left alone.
    private static func drainStandardInput() {
        guard isatty(STDIN_FILENO) == 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total = 0
        while total < drainLimit {
            let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            total += count
        }
    }
}

/// At most `limit` events per second per session; a hook stuck in a loop can't flood the app.
public struct AgentEventLimiter: Sendable {
    public let limit: Int
    private var windows: [String: (start: Double, count: Int)] = [:]
    public init(limit: Int = 20) { self.limit = limit }

    public mutating func allow(_ key: String, now: Double) -> Bool {
        if let window = windows[key], now - window.start < 1 {
            guard window.count < limit else { return false }
            windows[key] = (window.start, window.count + 1)
        } else {
            if windows.count > 1024 { windows = windows.filter { now - $0.value.start < 1 } }
            windows[key] = (now, 1)
        }
        return true
    }
}

/// Receives hook datagrams on an owner-only socket. Who may send is settled by the socket's 0700 directory; which session
/// an event is for, only by its nonce. Delivered on `queue`.
public final class AgentHookReceiver: @unchecked Sendable {
    public let path: String
    private let queue: DispatchQueue
    private let handler: @Sendable (_ nonce: String, _ event: String) -> Void
    private var source: DispatchSourceRead?
    private var limiter = AgentEventLimiter()

    public init(path: String, queue: DispatchQueue, handler: @escaping @Sendable (_ nonce: String, _ event: String) -> Void) {
        self.path = path; self.queue = queue; self.handler = handler
    }

    /// Replaces a stale socket left by an earlier process; anything else at the path is refused.
    public func start() throws {
        guard BrokerFiles.isOwnerOnlyDirectory(BrokerFiles.parent(path)), var address = BrokerFiles.address(path) else { throw BrokerServerError.socketDirectory }
        if let entry = BrokerFiles.entry(path) {
            guard entry.kind == .socket else { throw BrokerServerError.socket }
            unlink(path)
        }
        let fd = trellis_unix_datagram_socket()
        guard fd >= 0 else { throw BrokerServerError.socket }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0 else { close(fd); throw BrokerServerError.socket }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd) }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        if BrokerFiles.isOwnedSocket(path) { unlink(path) }
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: AgentHook.datagramLimit + 1)
        for _ in 0..<64 {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return }
            guard let (nonce, event) = AgentHook.decode(Array(buffer.prefix(count))) else { continue }
            var now = timespec()
            clock_gettime(CLOCK_MONOTONIC, &now)
            guard limiter.allow(nonce, now: Double(now.tv_sec) + Double(now.tv_nsec) / 1e9) else { continue }
            handler(nonce, event)
        }
    }
}
