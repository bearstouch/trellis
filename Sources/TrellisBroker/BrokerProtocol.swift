#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// The app ↔ `trellis-broker` wire format (FR-R03). Frames are `[u32 BE length][u8 kind][payload]`,
/// where the length counts the kind byte and the payload.
public enum BrokerProtocol {
    /// The highest version this build speaks; v2 adds remote workspaces (FR-RW01–FR-RW17).
    public static let version = 2
    /// The lowest version this build still speaks, so an updated app keeps a running older broker's sessions.
    public static let minimumVersion = 1
    public static let helperName = "trellis-broker"
    public static let frameLimit = 1_048_576
    /// Output, replay and input chunks never exceed this.
    public static let chunkLimit = 65_536
    public static let discoveryName = "broker.json"
    /// The variable carrying a shell-integration nonce; the broker keeps it in memory to return on attach.
    public static let nonceVariable = "TRELLIS_SHELL_INTEGRATION_NONCE"
    /// Optional events a client announces in `hello`; a broker sends one only to a client that listed it, so an
    /// older app (which can't decode it and would drop the connection) never receives it. No version bump needed.
    public static let inputRejectedFeature = "inputRejected"
    /// Remote brokers: a client silent this long is dropped (the app pings every 15 s), and a remote file read never exceeds this.
    public static let remoteClientTimeout: TimeInterval = 45
    public static let remoteFileLimit = 262_144
    public static let statLimit = 256
    /// Printed by `bridge` before the first frame; anything a login script printed before it is discarded.
    public static let syncPrefix = "TRELLIS-SYNC-1 "
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

/// v2: a login shell planned by the broker on its own host. The app supplies only what it knows from `welcome`:
/// the shell, environment overrides and an optional integration rewrite; the broker validates and falls back.
public struct BrokerLoginRequest: Codable, Equatable, Sendable {
    public var sessionID: UUID
    /// Absolute; nil or unusable means the account's login shell.
    public var shell: String?
    /// Absolute; nil or not a directory means the home directory.
    public var directory: String?
    public var environment: [String: String]
    public var integration: BrokerIntegration?
    public var columns: UInt16
    public var rows: UInt16
    public init(
        sessionID: UUID, shell: String?, directory: String?, environment: [String: String], integration: BrokerIntegration?, columns: UInt16, rows: UInt16
    ) {
        self.sessionID = sessionID; self.shell = shell; self.directory = directory; self.environment = environment
        self.integration = integration; self.columns = columns; self.rows = rows
    }
}

/// Applied only when the shell is the one it was planned for and `scriptPath` is a readable file; otherwise the plain
/// login shell starts (INT-01).
public struct BrokerIntegration: Codable, Equatable, Sendable {
    public var shell: String
    /// argv after argv[0].
    public var arguments: [String]
    public var environment: [String: String]
    public var scriptPath: String
    public init(shell: String, arguments: [String], environment: [String: String], scriptPath: String) {
        self.shell = shell; self.arguments = arguments; self.environment = environment; self.scriptPath = scriptPath
    }
}

/// What a v2 broker reports about its host in `welcome`.
public struct BrokerHostInfo: Codable, Equatable, Sendable {
    /// `uname` system name lowercased (`linux`, `darwin`) and machine (`x86_64`, `aarch64`, `arm64`).
    public var os: String
    public var arch: String
    public var user: String
    public var home: String
    /// The account's login shell.
    public var shell: String
    /// Raw host identifier (`/etc/machine-id` or the Darwin host UUID); the app hashes it before storing.
    public var machineID: String?
    /// The broker's resolved executable, which names its install directory.
    public var executable: String
    /// Set when the host's logind would end the broker at logout (`KillUserProcesses=yes`).
    public var sessionsEndAtLogout: Bool
    public init(os: String, arch: String, user: String, home: String, shell: String, machineID: String?, executable: String, sessionsEndAtLogout: Bool) {
        self.os = os; self.arch = arch; self.user = user; self.home = home; self.shell = shell; self.machineID = machineID
        self.executable = executable; self.sessionsEndAtLogout = sessionsEndAtLogout
    }
}

public struct BrokerPathInfo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, directory, symlink, missing, other }
    public var path: String
    public var kind: Kind
    /// Owned by the broker's user.
    public var owned: Bool
    public var size: Int64
    /// The symlink-resolved path when it exists.
    public var realPath: String?
    public init(path: String, kind: Kind, owned: Bool, size: Int64, realPath: String?) {
        self.path = path; self.kind = kind; self.owned = owned; self.size = size; self.realPath = realPath
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
    /// v2: the session's output position at the end of the replay; later output frames continue from it.
    public var offset: UInt64?
    /// v2: the replay is exactly the output after the requested `since`, with no reset.
    public var resumed: Bool?
    public init(record: BrokerSessionRecord, nonce: String?, passwordPrompt: Bool, truncated: Bool, offset: UInt64? = nil, resumed: Bool? = nil) {
        self.record = record; self.nonce = nonce; self.passwordPrompt = passwordPrompt; self.truncated = truncated
        self.offset = offset; self.resumed = resumed
    }
}

public enum BrokerMessage: Codable, Equatable, Sendable {
    /// `features`: optional events this client can decode; an older peer ignores the extra key.
    /// `protocolVersion` is the lowest version the client speaks; v2 clients add `maximumVersion` and, for remote
    /// brokers, the `clientID` the broker was started for.
    case hello(protocolVersion: Int, features: [String]? = nil, maximumVersion: Int? = nil, clientID: String? = nil)
    case welcome(protocolVersion: Int, brokerPID: Int32, info: BrokerHostInfo? = nil)
    case refused(reason: String)
    case spawn(BrokerSpawnRequest)
    case spawned(sessionID: UUID, processID: Int32)
    /// A request failed; `code` is SCREAMING_SNAKE, `errno` is set for system failures.
    case failed(code: String, errno: Int32)
    case list
    case sessions([BrokerSessionRecord])
    /// Replay frames for the session precede the `attached` reply.
    /// v2 `since`: the output position the client already shows; the replay is the exact rest when still held.
    case attach(sessionID: UUID, columns: UInt16, rows: UInt16, since: UInt64? = nil)
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
    /// Input was refused because the session already holds `inputLimit` unwritten bytes; nothing more is taken
    /// until that drains, so a paste is cut short rather than written with holes. Sent only to a client that
    /// announced `inputRejectedFeature`; older brokers never send it.
    case inputRejected(sessionID: UUID)
    // v2 (remote brokers only).
    case spawnLogin(BrokerLoginRequest)
    case ping(UInt64)
    case pong(UInt64)
    /// At most `statLimit` absolute paths; answered by `pathInfo` in the same order.
    case stat(paths: [String])
    case pathInfo([BrokerPathInfo])
    /// An allow-listed project or task file (FR-RW10–FR-RW12); answered by `fileData` or `failed`.
    case readFile(path: String, limit: Int)
    case fileData(Data)
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
    /// Remote brokers: the resolved executable serving the socket; bridges accept only a broker that runs it.
    public var executable: String?
    public init(protocolVersion: Int, socketPath: String, executable: String? = nil) {
        self.protocolVersion = protocolVersion; self.socketPath = socketPath; self.executable = executable
    }
}

extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}
