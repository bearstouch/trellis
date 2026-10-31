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
    /// Negotiated in `hello`; v2 messages are sent only when this is at least 2.
    public private(set) var protocolVersion = 0
    public private(set) var hostInfo: BrokerHostInfo?
    public var onClose: (() -> Void)?

    private struct WeakSink { weak var sink: (any BrokerSessionSink)? }
    private final class DecoderBox: @unchecked Sendable { var decoder = BrokerFrameDecoder() }

    /// Connects to `socketPath` and proves the listener is our user's `brokerExecutable`.
    public static func connect(socketPath: String, brokerExecutable: String) throws(BrokerClientError) -> BrokerConnection {
        guard BrokerFiles.isOwnedSocket(socketPath), let fd = BrokerFiles.connect(socketPath) else { throw .unavailable }
        guard BrokerFiles.peerRuns(fd, executable: brokerExecutable) else { systemClose(fd); throw .untrustedPeer }
        BrokerFiles.configure(fd)
        return BrokerConnection(fd: fd)
    }

    /// An already-authenticated stream: a socket pair in tests, or a remote link's ssh pipe, where SSH authenticated the
    /// host and the remote bridge checked the broker (FR-RW03). The connection owns and closes `fd`.
    public init(fd: Int32) {
        io = DispatchIO(type: .stream, fileDescriptor: fd, queue: readQueue) { @Sendable _ in systemClose(fd) }
        io.setLimit(lowWater: 1)
        readNext(DecoderBox())
    }

    /// Fails with `incompatible` when the broker speaks no version in `minimumVersion…version`. Remote links require
    /// v2 and name their client ID.
    public func hello(minimumVersion: Int = BrokerProtocol.minimumVersion, clientID: String? = nil) async throws {
        let message = BrokerMessage.hello(
            protocolVersion: minimumVersion, features: [BrokerProtocol.inputRejectedFeature], maximumVersion: BrokerProtocol.version, clientID: clientID)
        switch try await request(message) {
        case .welcome(let version, let pid, let info) where version >= minimumVersion && version <= BrokerProtocol.version:
            brokerPID = pid; protocolVersion = version; hostInfo = info
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
