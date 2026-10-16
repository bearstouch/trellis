import Darwin
import Foundation

/// AF_UNIX listener only; there is no TCP code path. Each connection runs its
/// blocking reads on a dedicated thread and hands bytes to a `ControlSession`.
public final class ControlServer: @unchecked Sendable {
    public static let maximumConnections = 16
    private let endpoint: ControlEndpoint
    private let handler: any ControlHandler
    /// Published in discovery and reported by system.info.
    public let instanceID: UUID
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clients = Set<Int32>()
    private var connectionFDs: [UUID: Int32] = [:]
    private var outboxes: [UUID: Outbox] = [:]
    private var discovery: ControlDiscovery?
    private var runtimeDirectory: String?

    public init(endpoint: ControlEndpoint, handler: any ControlHandler, instanceID: UUID = UUID()) {
        self.endpoint = endpoint; self.handler = handler; self.instanceID = instanceID
    }

    /// Binds the socket, then publishes discovery. Throws without publishing
    /// when the endpoint is unsafe or another instance is live.
    @discardableResult
    public func start() throws(ControlEndpointError) -> ControlDiscovery {
        let (directory, path) = try endpoint.prepare()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .io(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard var address = ControlEndpoint.unixAddress(path) else {
            close(fd); rmdir(directory)
            throw .pathTooLong
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let failure = errno
            close(fd); unlink(path); rmdir(directory)
            throw .io(failure)
        }
        do {
            try ControlEndpoint.verifySocket(path, uid: endpoint.uid)
        } catch {
            close(fd); unlink(path); rmdir(directory)
            throw error
        }
        let published = ControlDiscovery(protocolVersion: ControlDiscovery.currentProtocolVersion, instanceID: instanceID, socketPath: path)
        do {
            try endpoint.publish(published)
        } catch {
            close(fd); unlink(path); rmdir(directory)
            throw error
        }
        lock.withLock {
            listenFD = fd
            discovery = published
            runtimeDirectory = directory
        }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Trellis control accept"
        thread.start()
        return published
    }

    public func stop() {
        // Clients are shut down under the lock: a connection thread removes its
        // fd under the same lock before closing it, so a reused fd is never hit.
        let (fd, published) = lock.withLock { () -> (Int32, ControlDiscovery?) in
            defer { listenFD = -1; discovery = nil }
            for client in clients { shutdown(client, SHUT_RDWR) }
            return (listenFD, discovery)
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        if let published { endpoint.remove(published) }
    }

    /// Ends the given connections (for example after their grant is revoked).
    /// Their threads observe EOF, close the socket, and notify the handler.
    public func closeConnections(_ ids: Set<UUID>) {
        lock.withLock {
            for id in ids { if let fd = connectionFDs[id] { shutdown(fd, SHUT_RDWR) } }
        }
    }

    /// Whether the listener is currently accepting connections.
    public var isRunning: Bool { lock.withLock { listenFD >= 0 } }

    /// Queues a server-initiated message (an event) for a connection. Returns
    /// false when the connection is gone or its outbound queue exceeds 1 MiB,
    /// in which case the slow client is disconnected.
    public func push(_ data: Data, to connectionID: UUID) -> Bool {
        guard let outbox = lock.withLock({ outboxes[connectionID] }) else { return false }
        return outbox.enqueue(data)
    }

    /// Test seam: stops listening but leaves the socket and discovery files,
    /// which is what a crashed instance leaves behind.
    func closeListenerOnly() {
        let fd = lock.withLock { () -> Int32 in
            defer { listenFD = -1; discovery = nil }
            return listenFD
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var peerUID: uid_t = 0, peerGID: gid_t = 0
            let admitted = lock.withLock { () -> Bool in
                guard listenFD == fd, clients.count < Self.maximumConnections else { return false }
                clients.insert(client)
                return true
            }
            // Another user's peer is dropped here, before it can hold a connection slot.
            guard admitted, getpeereid(client, &peerUID, &peerGID) == 0, peerUID == endpoint.uid else {
                if admitted { _ = lock.withLock { clients.remove(client) } }
                close(client)
                continue
            }
            let session = ControlSession(peerUID: peerUID, expectedUID: endpoint.uid, handler: handler)
            let outbox = Outbox(fd: client)
            lock.withLock {
                connectionFDs[session.connectionID] = client
                outboxes[session.connectionID] = outbox
            }
            let writer = Thread { outbox.drain() }
            writer.name = "Trellis control writer"
            writer.start()
            let thread = Thread { [weak self] in self?.serve(client, session: session, outbox: outbox) }
            thread.name = "Trellis control connection"
            thread.start()
        }
    }

    private func serve(_ fd: Int32, session: ControlSession, outbox: Outbox) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            let chunk = Data(buffer.prefix(count))
            let (output, shouldClose) = Self.wait { await session.receive(chunk) }
            // Replies share the outbox with events, preserving order and the budget.
            guard output.isEmpty || outbox.enqueue(output) else { break }
            if shouldClose { break }
        }
        outbox.finish()
        outbox.waitUntilDrained()
        lock.withLock {
            clients.remove(fd)
            connectionFDs.removeValue(forKey: session.connectionID)
            outboxes.removeValue(forKey: session.connectionID)
        }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        Self.wait { await session.connectionClosed() }
    }

    /// Bridges a connection thread to async session work. Never called on the
    /// main thread, so main-actor handlers can make progress meanwhile.
    private static func wait<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Bounded per-connection outbound queue drained by its own writer thread, so
/// a client that stops reading never blocks event producers or grows memory.
final class Outbox: @unchecked Sendable {
    static let limit = 1_048_576
    private let fd: Int32
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var queued = 0
    private var finishing = false
    private var dead = false
    private var drained = false

    init(fd: Int32) { self.fd = fd }

    /// False when the connection is closed or this message would exceed the
    /// budget; the latter disconnects the client immediately.
    func enqueue(_ data: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !dead, !finishing else { return false }
        guard queued + data.count <= Self.limit else {
            dead = true
            queue.removeAll()
            queued = 0
            shutdown(fd, SHUT_RDWR)
            condition.broadcast()
            return false
        }
        queue.append(data)
        queued += data.count
        condition.broadcast()
        return true
    }

    /// Flushes what is queued, then lets the writer exit.
    func finish() {
        condition.lock()
        finishing = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilDrained() {
        condition.lock()
        while !drained { condition.wait() }
        condition.unlock()
    }

    func drain() {
        while true {
            condition.lock()
            while queue.isEmpty && !finishing && !dead { condition.wait() }
            if dead || (queue.isEmpty && finishing) {
                drained = true
                condition.broadcast()
                condition.unlock()
                return
            }
            let next = queue.removeFirst()
            queued -= next.count
            condition.unlock()
            var offset = 0
            while offset < next.count {
                let written = next.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), next.count - offset) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    condition.lock()
                    dead = true
                    queue.removeAll()
                    queued = 0
                    condition.broadcast()
                    condition.unlock()
                    shutdown(fd, SHUT_RDWR)
                    break
                }
                offset += written
            }
        }
    }
}
