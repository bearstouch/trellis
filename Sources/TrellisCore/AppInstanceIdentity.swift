import Foundation

/// Which Trellis this process is. The installed app (`com.bearstouch.trellis`) and development
/// builds (`swift run`, the feasibility bundle) each get their own instance lock,
/// activation notification, state directory and control socket, so both can run at once.
public struct AppInstanceIdentity: Equatable, Sendable {
    public static let production = "com.bearstouch.trellis"
    public static let development = "com.bearstouch.trellis.dev"
    /// Identities used before the move to the Bearstouch identifier; their data migrates once.
    public static let legacyProduction = "dev.trellis"
    public let identifier: String
    /// An unbundled executable has no bundle identifier and is always a development build.
    public init(bundleIdentifier: String?) { identifier = bundleIdentifier ?? Self.development }
    public var isDevelopment: Bool { identifier != Self.production }
    public func lockURL(in directory: URL, uid: uid_t = getuid()) -> URL {
        directory.appendingPathComponent("\(identifier)-\(uid).instance.lock")
    }
    public var activationNotification: String { "\(identifier).activateExistingInstance" }
}
