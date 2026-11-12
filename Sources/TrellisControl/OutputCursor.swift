import Foundation
import TrellisCore

/// Opaque stream cursor: instance + session + absolute byte offset.
/// A cursor from another session or app instance is rejected, never reinterpreted.
public struct OutputCursor: Equatable, Sendable {
    public let instanceID: UUID
    public let sessionID: UUID
    public let offset: UInt64

    public init(instanceID: UUID, sessionID: UUID, offset: UInt64) {
        self.instanceID = instanceID; self.sessionID = sessionID; self.offset = offset
    }

    public var token: String {
        var bytes = [UInt8]()
        withUnsafeBytes(of: instanceID.uuid) { bytes += $0 }
        withUnsafeBytes(of: sessionID.uuid) { bytes += $0 }
        withUnsafeBytes(of: offset.bigEndian) { bytes += $0 }
        return "oc1_"
            + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(token: String) {
        guard token.hasPrefix("oc1_"), token.utf8.count <= 64 else { return nil }
        var text = String(token.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), data.count == 40 else { return nil }
        let bytes = [UInt8](data)
        func uuid(_ at: Int) -> UUID {
            UUID(
                uuid: (
                    bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3], bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7],
                    bytes[at + 8], bytes[at + 9], bytes[at + 10], bytes[at + 11], bytes[at + 12], bytes[at + 13], bytes[at + 14], bytes[at + 15]
                ))
        }
        instanceID = uuid(0)
        sessionID = uuid(16)
        offset = bytes[32..<40].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
