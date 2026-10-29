import Darwin
import Foundation
import TrellisPOSIX

/// Receives one broker session's stream on the main actor.
@MainActor
public protocol BrokerSessionSink: AnyObject {
    func brokerOutput(_ data: Data)
    func brokerReplay(_ data: Data)
    func brokerExited(waitStatus: Int32)
    func brokerPrompt(_ active: Bool)
    func brokerDisconnected()
    /// The broker refused input over its per-session limit.
    func brokerInputRejected()
}

public enum BrokerClientError: Error, Equatable, Sendable {
    case unavailable, untrustedPeer, incompatible, closed, queueFull, timedOut
    case failed(code: String, errno: Int32)
}

/// The app's single connection to its broker. Reads and frame decoding run off the main thread;
/// frames are delivered in order on the main actor, one read (at most `chunkLimit` bytes) at a time.
/// Writes are bounded by `outboxLimit`.
@MainActor
public final class BrokerConnection {
    public static let outboxLimit = 4 * 1_048_576
    private let io: DispatchIO
    private let readQueue = DispatchQueue(label: "com.bearstouch.trellis.broker.client", qos: .userInitiated)
    private var nextRequest: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<BrokerMessage, any Error>] = [:]
    private var sinks: [UUID: WeakSink] = [:]
    private var outbox = 0
    public private(set) var isOpen = true
    public private(set) var brokerPID: Int32 = 0
    public var onClose: (() -> Void)?

    private struct WeakSink { weak var sink: (any BrokerSessionSink)? }
    private final class DecoderBox: @unchecked Sendable { var decoder = BrokerFrameDecoder() }

    /// Connects to `socketPath` and proves the listener is our user's `brokerExecutable`.
    public static func connect(socketPath: String, brokerExecutable: String) throws(BrokerClientError) -> BrokerConnection {
        guard BrokerFiles.isOwnedSocket(socketPath), var address = BrokerFiles.address(socketPath) else { throw .unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .unavailable }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard BrokerFiles.preventSigPipe(fd) else { Darwin.close(fd); throw .unavailable }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { Darwin.close(fd); throw .unavailable }
        guard BrokerFiles.peerRuns(fd, executable: brokerExecutable) else { Darwin.close(fd); throw .untrustedPeer }
        BrokerFiles.configure(fd)
        return BrokerConnection(fd: fd)
    }

    /// Internal so tests can drive a connection over a socket pair.
    init(fd: Int32) {
        io = DispatchIO(type: .stream, fileDescriptor: fd, queue: readQueue) { @Sendable _ in Darwin.close(fd) }
        io.setLimit(lowWater: 1)
        readNext(DecoderBox())
    }

    /// Fails with `incompatible` when the broker speaks another protocol version.
    public func hello() async throws {
        switch try await request(.hello(protocolVersion: BrokerProtocol.version, features: [BrokerProtocol.inputRejectedFeature])) {
        case .welcome(_, let pid): brokerPID = pid
        case .refused: close(); throw BrokerClientError.incompatible
        default: close(); throw BrokerClientError.incompatible
        }
    }

    public func request(_ message: BrokerMessage, timeout: Duration = .seconds(5)) async throws -> BrokerMessage {
        let id = nextRequest
        nextRequest &+= 1
        let frame = try BrokerFrame.control(BrokerEnvelope(requestID: id, message: message))
        return try await withCheckedThrowingContinuation { continuation in
            do { try send(frame) } catch { continuation.resume(throwing: error); return }
            pending[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.pending.removeValue(forKey: id)?.resume(throwing: BrokerClientError.timedOut)
            }
        }
    }

    /// Fire-and-forget control message; a reply, if any, is ignored.
    public func post(_ message: BrokerMessage) {
        guard let frame = try? BrokerFrame.control(BrokerEnvelope(requestID: nil, message: message)) else { return }
        try? send(frame)
    }

    public func sendInput(_ data: Data, sessionID: UUID) throws {
        let frames = BrokerFrame.stream(.input, sessionID: sessionID, bytes: data)
        // All or nothing: a send that can't fit whole never delivers its first chunks.
        guard isOpen else { throw BrokerClientError.closed }
        guard outbox + frames.reduce(0, { $0 + $1.encoded.count }) <= Self.outboxLimit else { throw BrokerClientError.queueFull }
        for frame in frames { try send(frame) }
    }

    /// Ends every session of a broker this app can't otherwise talk to, whatever its protocol version.
    public func sendStopAll() { try? send(BrokerFrame(kind: .stopAll, payload: Data())) }

    public func register(_ sink: any BrokerSessionSink, sessionID: UUID) { sinks[sessionID] = WeakSink(sink: sink) }
    public func unregister(sessionID: UUID) { sinks.removeValue(forKey: sessionID) }

    private func send(_ frame: BrokerFrame) throws {
        guard isOpen else { throw BrokerClientError.closed }
        let data = frame.encoded
        guard outbox + data.count <= Self.outboxLimit else { throw BrokerClientError.queueFull }
        outbox += data.count
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        let count = data.count
        io.write(offset: 0, data: payload, queue: .main) { [weak self] done, _, error in
            MainActor.assumeIsolated {
                guard let self, done || error != 0 else { return }
                self.outbox -= count
                if error != 0 { self.close() }
            }
        }
    }

    private nonisolated func readNext(_ box: DecoderBox) {
        io.read(offset: 0, length: BrokerProtocol.chunkLimit, queue: readQueue) { [weak self] done, data, error in
            var frames: [BrokerFrame] = []
            var ended = error != 0 || (done && (data?.isEmpty ?? true))
            if let data, !data.isEmpty {
                do { frames = try box.decoder.append(Data(data)) } catch { ended = true }
            }
            let deliver = frames, failed = ended
            let connection = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let connection else { return }
                    connection.receive(deliver)
                    if failed { connection.close(); return }
                    // The next read waits for the main actor to take this one, so a flood can't queue
                    // unbounded output for the UI; the broker then pauses its PTY reads (backpressure).
                    if done, connection.isOpen { connection.readNext(box) }
                }
            }
        }
    }

    private func receive(_ frames: [BrokerFrame]) {
        for frame in frames where isOpen {
            switch frame.kind {
            case .control:
                guard let envelope = frame.envelope else { close(); return }
                if let id = envelope.requestID {
                    pending.removeValue(forKey: id)?.resume(returning: envelope.message)
                    continue
                }
                switch envelope.message {
                case .exited(let id, let status): sinks[id]?.sink?.brokerExited(waitStatus: status)
                case .prompt(let id, let active): sinks[id]?.sink?.brokerPrompt(active)
                case .inputRejected(let id): sinks[id]?.sink?.brokerInputRejected()
                case .refused: close()
                default: break
                }
            case .output: if let (id, bytes) = frame.stream { sinks[id]?.sink?.brokerOutput(bytes) }
            case .replay: if let (id, bytes) = frame.stream { sinks[id]?.sink?.brokerReplay(bytes) }
            case .input, .stopAll: close()
            }
        }
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        io.close(flags: .stop)
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: BrokerClientError.closed) }
        let attached = sinks.values.compactMap(\.sink)
        sinks = [:]
        for sink in attached { sink.brokerDisconnected() }
        onClose?()
    }
}

/// Finds or starts the broker for one state directory: its socket lives in a fresh owner-only
/// directory under the per-user temporary folder, recorded in `<state>/broker.json`.
public struct BrokerLauncher: Sendable {
    public let stateDirectory: URL
    /// The bundled `trellis-broker`.
    public let helperPath: String
    /// This app's executable; the broker accepts only it as a client.
    public let clientPath: String
    public let runtimeRoot: URL
    public let idleExit: Int

    public init(stateDirectory: URL, helperPath: String, clientPath: String, runtimeRoot: URL = FileManager.default.temporaryDirectory, idleExit: Int = 30) {
        self.stateDirectory = stateDirectory; self.helperPath = helperPath; self.clientPath = clientPath; self.runtimeRoot = runtimeRoot; self.idleExit = idleExit
    }

    public var discoveryPath: String { stateDirectory.appendingPathComponent(BrokerProtocol.discoveryName).path }

    public static func currentExecutable() -> String? { BrokerFiles.executablePath(pid: getpid()) }

    public func discovery() -> BrokerDiscovery? {
        BrokerFiles.readOwnerFile(discoveryPath).flatMap { try? JSONDecoder().decode(BrokerDiscovery.self, from: $0) }
    }

    public func publish(socketPath: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(BrokerDiscovery(protocolVersion: BrokerProtocol.version, socketPath: socketPath)) else { return }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = BrokerFiles.writeOwnerFile(data, to: discoveryPath)
    }

    public func removeDiscovery() { unlink(discoveryPath) }

    /// Starts a detached broker and waits up to two seconds for its socket; returns the socket path.
    public func spawn() throws(BrokerClientError) -> String {
        var random = [UInt8](repeating: 0, count: 6)
        arc4random_buf(&random, random.count)
        let directory = runtimeRoot.appendingPathComponent("trellis-broker-" + random.map { String(format: "%02x", $0) }.joined()).path
        guard mkdir(directory, 0o700) == 0, BrokerFiles.isOwnerOnlyDirectory(directory) else { throw .unavailable }
        let socketPath = directory + "/s"
        guard socketPath.utf8.count <= BrokerFiles.socketPathLimit else { rmdir(directory); throw .unavailable }
        let argv: [String] = [helperPath, "--socket", socketPath, "--client", clientPath, "--idle-exit", String(idleExit)]
        let arguments = argv.map { strdup($0) }
        defer { arguments.forEach { free($0) } }
        // An empty environment: nothing of the app's environment reaches the broker.
        let environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let failure = helperPath.withCString { helper in
            (arguments + [nil]).withUnsafeBufferPointer { argv in
                environment.withUnsafeBufferPointer { envp in
                    trellis_spawn_detached(helper, argv.baseAddress, envp.baseAddress)
                }
            }
        }
        guard failure == 0 else { rmdir(directory); throw .unavailable }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if BrokerFiles.isOwnedSocket(socketPath) { return socketPath }
            usleep(20_000)
        }
        throw .timedOut
    }
}
