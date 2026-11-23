import Foundation

/// The animation on the lock screen (FR-LK05). Vault Dial is the default.
public enum LockScreenStyle: String, Codable, CaseIterable, Sendable {
    case vaultDial, redactedShell, cipherWall, ridgelines, signalLost
    public static let defaultStyle = Self.vaultDial
    public var displayName: String {
        switch self {
        case .vaultDial: L("Vault Dial")
        case .redactedShell: L("Redacted Shell")
        case .cipherWall: L("Cipher Wall")
        case .ridgelines: L("Ridgelines")
        case .signalLost: L("Signal Lost")
        }
    }
}
