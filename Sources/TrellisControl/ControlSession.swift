import Darwin
import Foundation
import TrellisCore

/// Fixed, sanitized errors (API-06). Standard JSON-RPC failures use their
/// reserved codes; application failures use -32000 with a stable `data.code`
/// and a `retryable` hint. Messages never echo client input or secrets.
public struct ControlError: Error, Equatable, Sendable {
    public let code: Int
    public let message: String
    /// Stable application code shared with the CLI (`AUTH_REQUIRED`, …).
    public let appCode: String?
    public let retryable: Bool
    /// Optional structured details, such as per-field validation messages or
    /// affected session IDs. Never contains terminal text or secrets.
    public let details: JSONValue?

    public init(code: Int, message: String, appCode: String? = nil, retryable: Bool = false, details: JSONValue? = nil) {
        self.code = code; self.message = message; self.appCode = appCode; self.retryable = retryable; self.details = details
    }

    /// An application error (-32000) from the API-06 code list.
    public static func application(_ appCode: String, _ message: String, retryable: Bool = false, details: JSONValue? = nil) -> Self {
        Self(code: -32000, message: message, appCode: appCode, retryable: retryable, details: details)
    }

    /// Attaches layout issues (key + message) as `data.issues`.
    public func withIssues(_ issues: [LayoutIssue]) -> Self {
        var object: [String: JSONValue] = [:]
        if case .object(let existing)? = details { object = existing }
        object["issues"] = LayoutJSON.issuesJSON(issues)
        return Self(code: code, message: message, appCode: appCode, retryable: retryable, details: .object(object))
    }

    public static func invalidParams(_ message: String, fields: [String: String] = [:]) -> Self {
        Self(code: -32602, message: message, details: fields.isEmpty ? nil : .object(["fields": .object(fields.mapValues(JSONValue.string))]))
    }

    public static let parse = Self(code: -32700, message: "Parse error: send one UTF-8 JSON object per line.")
    public static let invalidRequest = Self(code: -32600, message: "Invalid JSON-RPC 2.0 request.")
    public static let batch = Self(code: -32600, message: "Batch requests are not supported.")
    public static let notificationMutation = Self(code: -32600, message: "Mutating methods require a request id.")
    public static let methodNotFound = Self(code: -32601, message: "Method not found.")
    public static let invalidParams = Self(code: -32602, message: "Invalid params.")
    public static let internalError = Self(code: -32603, message: "Internal error.")
    public static let frameTooLarge = application("LIMIT_EXCEEDED", "Frames are limited to 1 MiB.")
    public static let responseTooLarge = application("LIMIT_EXCEEDED", "The response exceeded 1 MiB; request less data.")
    public static let unauthenticated = application("AUTH_REQUIRED", "Authenticate with auth.authenticate first.")
    public static let authenticationFailed = application("AUTH_REQUIRED", "Authentication failed.")
    public static let permissionDenied = application("PERMISSION_DENIED", "This grant does not allow that operation.")
    public static let notFound = application("NOT_FOUND", "No such resource is available to this grant.")
    public static let unsupportedVersion = application("UNSUPPORTED_VERSION", "Use protocolVersion 1.")
    public static let rateLimited = application("LIMIT_EXCEEDED", "Too many failed authentication attempts. Wait and try again.", retryable: true)
}

public enum ControlRequestID: Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)

    var json: JSONValue {
        switch self {
        case .string(let value): .string(value)
        case .number(let value): .number(value)
        }
    }
}

public struct ControlRequest: Equatable, Sendable {
    public let id: ControlRequestID?
    public let method: String
    public let params: JSONValue?
}

/// The authenticated principal for one connection, backed by its grant.
public struct ControlIdentity: Equatable, Sendable {
    public let connectionID: UUID
    public let peerUID: uid_t
    public let grantID: UUID?
    /// The protocol negotiated by `auth.authenticate`: 1, or 2 when the app runs with `--automation-v2`.
    public let protocolVersion: Int
    /// The grant's revision when this connection authenticated; an edit that narrows the grant past it ends the
    /// authentication (`AUTH_REQUIRED`).
    public let grantRevision: UInt64?
    public init(connectionID: UUID, peerUID: uid_t, grantID: UUID? = nil, protocolVersion: Int = 1, grantRevision: UInt64? = nil) {
        self.connectionID = connectionID; self.peerUID = peerUID; self.grantID = grantID; self.protocolVersion = protocolVersion
        self.grantRevision = grantRevision
    }
}

/// Domain entry point. Implementations route into the shared command service;
/// the session guarantees `dispatch` only runs for an authenticated identity.
public protocol ControlHandler: Sendable {
    func authenticate(_ params: JSONValue?, connectionID: UUID, peerUID: uid_t) async -> Result<(ControlIdentity, JSONValue), ControlError>
    func dispatch(_ method: String, params: JSONValue?, identity: ControlIdentity) async -> Result<JSONValue, ControlError>
    /// Called once when the connection ends (subscriptions, rate limits).
    func disconnected(connectionID: UUID) async
    /// Protocol versions `auth.authenticate` accepts; 2 only with `--automation-v2` until the switch.
    var supportedProtocolVersions: [Int] { get }
}

extension ControlHandler {
    public func disconnected(connectionID: UUID) async {}
    public var supportedProtocolVersions: [Int] { [1] }
}

/// No grants exist yet, so every authentication attempt fails and no domain
/// method is reachable.
public struct RejectingControlHandler: ControlHandler {
    public init() {}
    public func authenticate(_ params: JSONValue?, connectionID: UUID, peerUID: uid_t) async -> Result<(ControlIdentity, JSONValue), ControlError> {
        .failure(.authenticationFailed)
    }
    public func dispatch(_ method: String, params: JSONValue?, identity: ControlIdentity) async -> Result<JSONValue, ControlError> {
        .failure(.methodNotFound)
    }
}

public enum ControlMethods {
    /// Methods that never change state. Anything else is treated as mutating,
    /// so a new method is safe by default.
    public static let readOnly: Set<String> = [
        "system.info", "space.list", "space.get", "tab.list", "tab.get", "session.get", "session.readOutput",
        "host.list", "host.get", "theme.list", "theme.get", "theme.validate", "theme.export", "appearance.get", "layout.export", "layout.plan", "layout.validate"
    ]
    public static func isMutating(_ method: String) -> Bool { !readOnly.contains(canonical(method, params: nil).method) }

    /// Deprecated names from before windows were renamed spaces (`window.*`, `windowId`, `windowIds`) mapped to the
    /// current ones. A param already given under its new name wins; replies always use the new names.
    public static func canonical(_ method: String, params: JSONValue?) -> (method: String, params: JSONValue?) {
        let method = method.hasPrefix("window.") ? "space." + method.dropFirst("window.".count) : method
        guard case .object(var object)? = params else { return (method, params) }
        for (old, new) in [("windowId", "spaceId"), ("windowIds", "spaceIds")] {
            guard let value = object.removeValue(forKey: old) else { continue }
            if object[new] == nil { object[new] = value }
        }
        return (method, .object(object))
    }
}

/// Socket-independent protocol state for one connection: framing, JSON-RPC
/// validation, peer check, and the authentication gate. Frames are handled
/// strictly in order.
public actor ControlSession {
    public nonisolated let connectionID = UUID()
    private let peerUID: uid_t
    private let expectedUID: uid_t
    private let handler: any ControlHandler
    private var framer = ControlFramer()
    private var identity: ControlIdentity?
    /// The protocol replies are shaped for: the last supported version a client asked for. Starts at 1, so a client
    /// that never asks for 2 sees exactly the v1 wire format.
    private var wireVersion = 1
    private var closed = false
    /// Writes a reply out of order (the server's outbox). With it, a waiting protocol 2 `events.poll` is answered when it
    /// returns while the frames after it are handled meanwhile; without it (tests), it is answered in order.
    private let reply: (@Sendable (Data) -> Bool)?
    private var waiting: [UUID: Task<Void, Never>] = [:]

    public init(peerUID: uid_t, expectedUID: uid_t = geteuid(), handler: any ControlHandler, reply: (@Sendable (Data) -> Bool)? = nil) {
        self.peerUID = peerUID; self.expectedUID = expectedUID; self.handler = handler; self.reply = reply
    }

    /// Returns the bytes to write and whether the connection must close.
    public func receive(_ bytes: Data) async -> (output: Data, close: Bool) {
        guard !closed else { return (Data(), true) }
        // Another user's process never reaches parsing or dispatch.
        guard peerUID == expectedUID else { return finish(Data()) }
        let frames: [Data]
        do { frames = try framer.append(bytes) } catch { return finish(Self.encode(error: .frameTooLarge, id: nil, version: wireVersion)) }
        var output = Data()
        for frame in frames {
            guard String(data: frame, encoding: .utf8) != nil else {
                // Invalid UTF-8 is malformed framing: best-effort error, then close.
                output.append(Self.encode(error: .parse, id: nil))
                return finish(output)
            }
            if frame.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            if let response = await handle(frame) { output.append(response) }
        }
        return (output, false)
    }

    public func connectionClosed() async {
        closed = true
        for task in waiting.values { task.cancel() }
        waiting.removeAll()
        await handler.disconnected(connectionID: connectionID)
    }

    /// A poll that may wait, and a method that may wait on a remote host or the person (`MethodSpecV2.waits`), run beside
    /// later frames. JSON-RPC replies carry their request's id, so order doesn't matter. At most `maximumWaiting` do at
    /// once per connection; more are answered in order, which only delays the connection, never refuses a call.
    private func waitsOutOfOrder(_ request: ControlRequest) -> Bool {
        guard reply != nil, wireVersion == 2, identity != nil, waiting.count < Self.maximumWaiting else { return false }
        var params: [String: JSONValue] = [:]
        if case .object(let object)? = request.params { params = object }
        if MethodCatalogV2.spec(request.method)?.waits(for: params) == true { return true }
        guard request.method == "events.poll", case .number(let timeout)? = request.params?["timeoutMs"] else { return false }
        return timeout > 0
    }

    static let maximumWaiting = 16

    private func answerLater(_ request: ControlRequest, id: ControlRequestID, identity: ControlIdentity) {
        let key = UUID()
        waiting[key] = Task { [handler] in
            let result = await handler.dispatch(request.method, params: request.params, identity: identity)
            self.finishWaiting(key, result: result, id: id, identity: identity)
        }
    }

    private func finishWaiting(_ key: UUID, result: Result<JSONValue, ControlError>, id: ControlRequestID, identity finished: ControlIdentity) {
        waiting.removeValue(forKey: key)
        guard !closed, let reply else { return }
        if case .failure(let error) = result, error.appCode == "AUTH_REQUIRED", identity == finished { identity = nil }
        _ = reply(encoded(result, id: id))
    }

    private func encoded(_ result: Result<JSONValue, ControlError>, id: ControlRequestID) -> Data {
        switch result {
        case .success(let value):
            let encoded = Self.encode(result: value, id: id)
            return encoded.count <= ControlFramer.maximumFrame ? encoded : Self.encode(error: .responseTooLarge, id: id, version: wireVersion)
        case .failure(let error): return Self.encode(error: error, id: id, version: wireVersion)
        }
    }

    private func finish(_ output: Data) -> (output: Data, close: Bool) {
        closed = true
        return (output, true)
    }

    private func handle(_ frame: Data) async -> Data? {
        let request: ControlRequest
        switch Self.parse(frame) {
        case .failure(let error): return Self.encode(error: error, id: nil)
        case .success(let parsed): request = parsed
        }
        guard let id = request.id else {
            // Notifications get no reply and are never dispatched; mutations are refused.
            let mutating = wireVersion == 2 ? MethodCatalogV2.isMutating(request.method) : ControlMethods.isMutating(request.method)
            return mutating ? Self.encode(error: .notificationMutation, id: nil, version: wireVersion) : nil
        }
        let result: Result<JSONValue, ControlError>
        if request.method == "auth.authenticate" {
            if case .number(let requested)? = request.params?["protocolVersion"], let version = Int(exactly: requested),
                handler.supportedProtocolVersions.contains(version)
            {
                wireVersion = version
            }
            switch await handler.authenticate(request.params, connectionID: connectionID, peerUID: peerUID) {
            case .success(let (identity, payload)):
                self.identity = identity
                result = .success(payload)
            case .failure(let error):
                identity = nil
                result = .failure(error)
            }
        } else if let identity, waitsOutOfOrder(request) {
            answerLater(request, id: id, identity: identity)
            return nil
        } else if let identity {
            result = await handler.dispatch(request.method, params: request.params, identity: identity)
            // An expired or revoked grant ends this connection's authentication.
            if case .failure(let error) = result, error.appCode == "AUTH_REQUIRED" { self.identity = nil }
        } else {
            result = .failure(.unauthenticated)
        }
        return encoded(result, id: id)
    }

    /// Bounds the recursive `JSONValue` decoder: a 1 MiB frame of `[` would
    /// otherwise overflow a cooperative-pool thread's stack (NFR-R04).
    public static let maximumNesting = 64

    static func parse(_ frame: Data) -> Result<ControlRequest, ControlError> {
        guard !exceedsNesting(frame) else { return .failure(.parse) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame) else { return .failure(.parse) }
        if case .array = value { return .failure(.batch) }
        guard case .object(let object) = value, object["jsonrpc"] == .string("2.0"),
            case .string(let method) = object["method"], !method.isEmpty, method.utf8.count <= 128
        else { return .failure(.invalidRequest) }
        let id: ControlRequestID?
        switch object["id"] {
        case nil: id = nil
        case .string(let value)?: id = .string(value)
        case .number(let value)?: id = .number(value)
        default: return .failure(.invalidRequest)
        }
        switch object["params"] {
        case nil, .object?, .array?: break
        default: return .failure(.invalidRequest)
        }
        return .success(ControlRequest(id: id, method: method, params: object["params"]))
    }

    public static func exceedsNesting(_ frame: Data) -> Bool {
        var depth = 0, inString = false, escaped = false
        for byte in frame {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x5B || byte == 0x7B {
                depth += 1
                if depth > maximumNesting { return true }
            } else if byte == 0x5D || byte == 0x7D {
                depth -= 1
            }
        }
        return false
    }

    static func encode(result: JSONValue, id: ControlRequestID) -> Data {
        line(.object(["jsonrpc": .string("2.0"), "id": id.json, "result": result]))
    }

    /// v1 merges details into `data`; v2 (API2-03) sends `data: {code, message, retryable, details?}` for application
    /// errors. JSON-RPC errors carry their details (such as `fields`) directly in `data` in both.
    static func encode(error: ControlError, id: ControlRequestID?, version: Int = 1) -> Data {
        var body: [String: JSONValue] = ["code": .number(Double(error.code)), "message": .string(error.message)]
        var data: [String: JSONValue] = [:]
        if version == 2, let appCode = error.appCode {
            data = ["code": .string(appCode), "message": .string(error.message), "retryable": .bool(error.retryable)]
            if let details = error.details { data["details"] = details }
            body["data"] = .object(data)
            return line(.object(["jsonrpc": .string("2.0"), "id": id?.json ?? .null, "error": .object(body)]))
        }
        if let appCode = error.appCode { data = ["code": .string(appCode), "retryable": .bool(error.retryable)] }
        if case .object(let details)? = error.details { data.merge(details) { current, _ in current } }
        if !data.isEmpty { body["data"] = .object(data) }
        return line(.object(["jsonrpc": .string("2.0"), "id": id?.json ?? .null, "error": .object(body)]))
    }

    private static func line(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data(#"{"error":{"code":-32603,"message":"Internal error."},"id":null,"jsonrpc":"2.0"}"#.utf8)
        data.append(0x0A)
        return data
    }
}
