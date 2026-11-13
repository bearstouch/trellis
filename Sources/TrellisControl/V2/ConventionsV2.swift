import CryptoKit
import Foundation
import TrellisCore

/// API2-02 conventions shared by every v2 method: IDs, absent values, results, revisions, idempotency, time and numbers.
public enum ConventionsV2 {
    // MARK: IDs

    /// UUIDs are written lowercase.
    public static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
    public static func idJSON(_ uuid: UUID) -> JSONValue { .string(id(uuid)) }
    /// UUIDs are accepted in any case.
    public static func parseID(_ text: String) -> UUID? { text.utf8.count == 36 ? UUID(uuidString: text) : nil }

    // MARK: Numbers and time

    /// Integers in a JSON number exactly representable as `Int64` (|n| ≤ 2^53).
    public static func integer(_ number: Double) -> Int64? {
        guard number.isFinite, number == number.rounded(), abs(number) <= 9_007_199_254_740_992 else { return nil }
        return Int64(number)
    }

    public static func number<T: BinaryInteger>(_ value: T) -> JSONValue { .number(Double(value)) }

    /// RFC 3339 UTC with milliseconds (`2026-11-11T14:02:11.402Z`). The milliseconds are rounded once from the
    /// interval, so the text never depends on binary rounding of the fraction.
    public static func timestamp(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        let seconds = (milliseconds / 1_000).rounded(.down)
        let fraction = Int(milliseconds - seconds * 1_000)
        let whole = Date(timeIntervalSince1970: seconds).formatted(.iso8601)
        return String(whole.dropLast()) + "." + String(format: "%03d", fraction) + "Z"
    }

    // MARK: Results

    /// `{"<type>": value}`, plus `workspaceRevision` when the call changed the workspace.
    public static func resource(_ type: String, _ value: JSONValue, workspaceRevision: UInt64? = nil) -> JSONValue {
        var object: [String: JSONValue] = [type: value]
        if let workspaceRevision { object["workspaceRevision"] = number(workspaceRevision) }
        return .object(object)
    }

    /// `{"<plural>": [...], "revision", "nextCursor"?}`; `revision` is the container's (the host library has none).
    public static func list(_ plural: String, _ items: [JSONValue], revision: UInt64?, nextCursor: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [plural: .array(items)]
        if let revision { object["revision"] = number(revision) }
        if let nextCursor { object["nextCursor"] = .string(nextCursor) }
        return .object(object)
    }

    /// `{"deleted": {"kind", "id"}, "workspaceRevision"}` for close and delete methods; deleting a host leaves the
    /// workspace unchanged, so it has no `workspaceRevision`.
    public static func deleted(kind: String, id: UUID, workspaceRevision: UInt64?) -> JSONValue {
        var object: [String: JSONValue] = ["deleted": .object(["kind": .string(kind), "id": idJSON(id)])]
        if let workspaceRevision { object["workspaceRevision"] = number(workspaceRevision) }
        return .object(object)
    }

    // MARK: Concurrency

    /// `expectedRevision` honoured: a mismatch is `CONFLICT` with `details.currentRevision`.
    public static func checkRevision(expected: UInt64?, current: UInt64) throws(ControlError) {
        guard let expected, expected != current else { return }
        throw .api(.conflict, "The resource changed since that revision. Read it again and retry.", details: .object(["currentRevision": number(current)]))
    }

    /// 1–128 printable ASCII characters (space through tilde).
    public static func isValidIdempotencyKey(_ key: String) -> Bool {
        (1...128).contains(key.utf8.count) && key.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }
}

/// A JSON object that omits absent values: nil and empty strings are never written as placeholders (API2-02).
public struct ResultObjectV2: Sendable, Equatable {
    public private(set) var fields: [String: JSONValue] = [:]
    public init() {}

    public var json: JSONValue { .object(fields) }

    public mutating func set(_ key: String, _ value: String?) { fields[key] = value.flatMap { $0.isEmpty ? nil : .string($0) } }
    public mutating func set(_ key: String, _ value: UUID?) { fields[key] = value.map(ConventionsV2.idJSON) }
    public mutating func set(_ key: String, _ value: [UUID]) { fields[key] = .array(value.map(ConventionsV2.idJSON)) }
    public mutating func set(_ key: String, _ value: Bool?) { fields[key] = value.map(JSONValue.bool) }
    public mutating func set<T: BinaryInteger>(_ key: String, _ value: T?) { fields[key] = value.map { .number(Double($0)) } }
    public mutating func set(_ key: String, _ value: Double?) { fields[key] = value.flatMap { $0.isFinite ? .number($0) : nil } }
    public mutating func set(_ key: String, _ value: Date?) { fields[key] = value.map { .string(ConventionsV2.timestamp($0)) } }
    public mutating func set(_ key: String, _ value: JSONValue?) { fields[key] = value == .null ? nil : value }
}

/// Validated v2 parameters with typed accessors. Validation has already run, so a mismatch here is a programming error
/// in the caller; it still fails safely as -32602.
public struct ParamsV2: Sendable, Equatable {
    public let values: [String: JSONValue]
    public init(_ values: [String: JSONValue]) { self.values = values }

    public subscript(key: String) -> JSONValue? { values[key] }

    private func invalid(_ key: String, _ expectation: String) -> ControlError { .invalidParams("Invalid \(key).", fields: [key: expectation]) }

    public func optionalString(_ key: String) throws(ControlError) -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw invalid(key, "string")
        }
    }
    public func string(_ key: String) throws(ControlError) -> String {
        guard let value = try optionalString(key) else { throw invalid(key, "string") }
        return value
    }
    public func optionalUUID(_ key: String) throws(ControlError) -> UUID? {
        guard let text = try optionalString(key) else { return nil }
        guard let id = ConventionsV2.parseID(text) else { throw invalid(key, "UUID") }
        return id
    }
    public func uuid(_ key: String) throws(ControlError) -> UUID {
        guard let id = try optionalUUID(key) else { throw invalid(key, "UUID") }
        return id
    }
    public func optionalBool(_ key: String) throws(ControlError) -> Bool? {
        switch values[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        default: throw invalid(key, "boolean")
        }
    }
    public func optionalInteger(_ key: String) throws(ControlError) -> Int64? {
        switch values[key] {
        case nil, .null?: return nil
        case .number(let number)?:
            guard let value = ConventionsV2.integer(number) else { throw invalid(key, "integer") }
            return value
        default: throw invalid(key, "integer")
        }
    }

    public func bool(_ key: String) throws(ControlError) -> Bool {
        guard let value = try optionalBool(key) else { throw invalid(key, "boolean") }
        return value
    }
    public func optionalDouble(_ key: String) throws(ControlError) -> Double? {
        switch values[key] {
        case nil, .null?: return nil
        case .number(let number)? where number.isFinite: return number
        default: throw invalid(key, "number")
        }
    }
    public func uuids(_ key: String) throws(ControlError) -> [UUID] {
        guard case .array(let items)? = values[key] else { throw invalid(key, "array of UUIDs") }
        var ids: [UUID] = []
        for item in items {
            guard case .string(let text) = item, let id = ConventionsV2.parseID(text) else { throw invalid(key, "array of UUIDs") }
            ids.append(id)
        }
        return ids
    }
    /// nil when absent or null.
    public func optionalStrings(_ key: String) throws(ControlError) -> [String]? {
        switch values[key] {
        case nil, .null?: return nil
        case .array(let items)?:
            var strings: [String] = []
            for item in items {
                guard case .string(let text) = item else { throw invalid(key, "array of strings") }
                strings.append(text)
            }
            return strings
        default: throw invalid(key, "array of strings")
        }
    }
    /// A `.structure` param's fields; nil when absent or null.
    public func optionalObject(_ key: String) throws(ControlError) -> ParamsV2? {
        switch values[key] {
        case nil, .null?: return nil
        case .object(let object)?: return ParamsV2(object)
        default: throw invalid(key, "object")
        }
    }
    /// Sent at all, `null` included (update parameters that clear).
    public func sent(_ key: String) -> Bool { values[key] != nil }

    public var expectedRevision: UInt64? { (try? optionalInteger("expectedRevision")).flatMap { $0.flatMap { $0 >= 0 ? UInt64($0) : nil } } }
    public var idempotencyKey: String? { (try? optionalString("idempotencyKey")) ?? nil }
}

/// List pagination (API2-02): `limit` (default 100, at most 500) and an opaque `cursor` bound to one list method.
public struct PageV2: Sendable, Equatable {
    public static let defaultLimit = 100
    public static let maximumLimit = 500

    public let method: String
    public let limit: Int
    public let offset: Int

    public init(method: String, limit: Int = Self.defaultLimit, offset: Int = 0) {
        self.method = method; self.limit = min(max(limit, 1), Self.maximumLimit); self.offset = max(offset, 0)
    }

    /// Reads `limit` and `cursor`; a cursor from another list method, or not one of ours, is `INVALID_CURSOR`.
    public init(_ params: ParamsV2, method: String) throws(ControlError) {
        let limit = try params.optionalInteger("limit").map(Int.init) ?? Self.defaultLimit
        guard (1...Self.maximumLimit).contains(limit) else { throw .invalidParams("Invalid limit.", fields: ["limit": "integer 1–\(Self.maximumLimit)"]) }
        var offset = 0
        if let cursor = try params.optionalString("cursor") {
            guard let decoded = Self.decode(cursor, method: method) else {
                throw .api(.invalidCursor, "That cursor doesn't belong to this list. Start again without a cursor.")
            }
            offset = decoded
        }
        self.init(method: method, limit: limit, offset: offset)
    }

    /// The items on this page and the cursor for the next one, if any remain.
    public func slice<T>(_ items: [T]) -> (items: [T], nextCursor: String?) {
        guard offset < items.count else { return ([], nil) }
        let end = min(items.count, offset + limit)
        return (Array(items[offset..<end]), end < items.count ? Self.encode(offset: end, method: method) : nil)
    }

    /// Signs cursors so only this app instance's own can be used: a cursor from another list, another launch, or with
    /// an edited offset is `INVALID_CURSOR`, never a silently different page.
    private static let cursorKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func tag(_ payload: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: cursorKey)).prefix(16)) }

    static func encode(offset: Int, method: String) -> String {
        let payload = Data("c1|\(method)|\(offset)".utf8)
        return base64URL(payload) + "." + base64URL(tag(payload))
    }

    static func decode(_ cursor: String, method: String) -> Int? {
        let halves = cursor.split(separator: ".", omittingEmptySubsequences: false)
        guard halves.count == 2, let payload = data(base64URL: String(halves[0])), let tag = data(base64URL: String(halves[1])),
            tag.count == 16, zip(Self.tag(payload), tag).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0, let text = String(data: payload, encoding: .utf8)
        else { return nil }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "c1", parts[1] == method, let offset = Int(parts[2]), offset >= 0 else { return nil }
        return offset
    }

    private static func data(base64URL text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

extension ControlError {
    /// An application error from the registry; `retryable` defaults to the code's registry value.
    public static func api(_ code: APIErrorCode, _ message: String, retryable: Bool? = nil, details: JSONValue? = nil) -> Self {
        .application(code.rawValue, message, retryable: retryable ?? code.defaultRetryable, details: details)
    }
}
