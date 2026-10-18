import Foundation

/// The app ↔ `trellis-broker` wire format (FR-R03). Frames are `[u32 BE length][u8 kind][payload]`,
/// where the length counts the kind byte and the payload.
public enum BrokerProtocol {
    public static let version = 1
    public static let helperName = "trellis-broker"
    public static let frameLimit = 1_048_576
    /// Output, replay and input chunks never exceed this.
    public static let chunkLimit = 65_536
    public static let discoveryName = "broker.json"
    /// The variable carrying a shell-integration nonce; the broker keeps it in memory to return on attach.
    public static let nonceVariable = "TRELLIS_SHELL_INTEGRATION_NONCE"
}

public enum BrokerFrameKind: UInt8, Sendable {
    case control = 0, input = 1, output = 2, replay = 3
    /// Accepted from an authenticated peer of any protocol version, so a newer app can always end an older broker.
    case stopAll = 255
}

public struct BrokerFrame: Equatable, Sendable {
    public let kind: BrokerFrameKind
    public let payload: Data
    public init(kind: BrokerFrameKind, payload: Data) { self.kind = kind; self.payload = payload }

    public var encoded: Data {
        var length = UInt32(payload.count + 1).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(kind.rawValue)
        data.append(payload)
        return data
    }

    public static func control(_ envelope: BrokerEnvelope) throws -> BrokerFrame {
        BrokerFrame(kind: .control, payload: try JSONEncoder().encode(envelope))
    }

    /// One session's bytes, split into chunks of at most `chunkLimit`.
    public static func stream(_ kind: BrokerFrameKind, sessionID: UUID, bytes: Data) -> [BrokerFrame] {
        var frames: [BrokerFrame] = []
        var offset = bytes.startIndex
        repeat {
            let end = bytes.index(offset, offsetBy: BrokerProtocol.chunkLimit, limitedBy: bytes.endIndex) ?? bytes.endIndex
            frames.append(BrokerFrame(kind: kind, payload: sessionID.data + bytes[offset..<end]))
            offset = end
        } while offset < bytes.endIndex
        return frames
    }

    /// The session and bytes of an input, output or replay frame.
    public var stream: (sessionID: UUID, bytes: Data)? {
        guard kind != .control, kind != .stopAll, payload.count >= 16 else { return nil }
        let start = payload.startIndex
        let id = payload[start..<start + 16].withUnsafeBytes { raw in UUID(uuid: raw.loadUnaligned(as: uuid_t.self)) }
        return (id, Data(payload[(start + 16)...]))
    }

    public var envelope: BrokerEnvelope? {
        guard kind == .control else { return nil }
        return try? JSONDecoder().decode(BrokerEnvelope.self, from: payload)
    }
}

public enum BrokerFrameError: Error, Equatable, Sendable { case oversized, unknownKind }

/// Incremental decoding; a malformed stream throws and the connection must close.
public struct BrokerFrameDecoder: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws(BrokerFrameError) -> [BrokerFrame] {
        buffer.append(data)
        var frames: [BrokerFrame] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= BrokerProtocol.frameLimit else { throw .oversized }
            guard buffer.count >= 4 + length else { break }
            guard let kind = BrokerFrameKind(rawValue: buffer[start + 4]) else { throw .unknownKind }
            frames.append(BrokerFrame(kind: kind, payload: Data(buffer[(start + 5)..<(start + 4 + length)])))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return frames
    }
}

public struct BrokerSpawnRequest: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var executable: String
    /// argv including argv[0].
    public var arguments: [String]
    public var environment: [String]
    public var directory: String
    public var columns: UInt16
    public var rows: UInt16
    public init(sessionID: UUID, executable: String, arguments: [String], environment: [String], directory: String, columns: UInt16, rows: UInt16) {
        self.sessionID = sessionID; self.executable = executable; self.arguments = arguments; self.environment = environment
        self.directory = directory; self.columns = columns; self.rows = rows
    }
}

public struct BrokerSessionRecord: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var processID: Int32
    public var running: Bool
    /// The raw `waitpid` status once the session ended.
    public var waitStatus: Int32?
    public init(sessionID: UUID, processID: Int32, running: Bool, waitStatus: Int32?) {
        self.sessionID = sessionID; self.processID = processID; self.running = running; self.waitStatus = waitStatus
    }
    /// Shell-style exit code: the status, or 128 + signal; matches `PTYProcess`.
    public var exitCode: Int32? { waitStatus.map(Self.exitCode) }
    public static func exitCode(_ status: Int32) -> Int32 { (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
}

public struct BrokerAttachment: Codable, Equatable, Sendable {
    public var record: BrokerSessionRecord
    public var nonce: String?
    public var passwordPrompt: Bool
    /// The ring evicted older output; the replay starts at a line boundary after a reset.
    public var truncated: Bool
    public init(record: BrokerSessionRecord, nonce: String?, passwordPrompt: Bool, truncated: Bool) {
        self.record = record; self.nonce = nonce; self.passwordPrompt = passwordPrompt; self.truncated = truncated
    }
}

public enum BrokerMessage: Codable, Equatable, Sendable {
    case hello(protocolVersion: Int)
    case welcome(protocolVersion: Int, brokerPID: Int32)
    case refused(reason: String)
    case spawn(BrokerSpawnRequest)
    case spawned(sessionID: UUID, processID: Int32)
    /// A request failed; `code` is SCREAMING_SNAKE, `errno` is set for system failures.
    case failed(code: String, errno: Int32)
    case list
    case sessions([BrokerSessionRecord])
    /// Replay frames for the session precede the `attached` reply.
    case attach(sessionID: UUID, columns: UInt16, rows: UInt16)
    case attached(BrokerAttachment)
    case resize(sessionID: UUID, columns: UInt16, rows: UInt16)
    case signal(sessionID: UUID, signal: Int32)
    /// Forgets an ended session's record and output.
    case release(sessionID: UUID)
    /// Stops forwarding output; sessions keep running.
    case detach
    case ok
    case exited(sessionID: UUID, waitStatus: Int32)
    case prompt(sessionID: UUID, active: Bool)
}

public struct BrokerEnvelope: Codable, Equatable, Sendable {
    /// Set on requests and echoed by their reply; nil for events.
    public var requestID: UInt64?
    public var message: BrokerMessage
    public init(requestID: UInt64?, message: BrokerMessage) { self.requestID = requestID; self.message = message }
}

/// Where the app found or started this state directory's broker (`<state>/broker.json`).
public struct BrokerDiscovery: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var socketPath: String
    public init(protocolVersion: Int, socketPath: String) { self.protocolVersion = protocolVersion; self.socketPath = socketPath }
}

extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}
