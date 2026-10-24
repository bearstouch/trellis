import CryptoKit
import Foundation

/// Which Trellis this process is. The installed app (`com.bearstouch.trellis`) and development
/// builds (`swift run`, the feasibility bundle) each get their own instance lock,
/// activation notification, state directory and control socket, so both can run at once.
/// A `--state-directory` launch is its own instance too, so it never hands off to one using another workspace.
public struct AppInstanceIdentity: Equatable, Sendable {
    public static let production = "com.bearstouch.trellis"
    public static let development = "com.bearstouch.trellis.dev"
    /// Identities used before the move to the Bearstouch identifier; their data migrates once.
    public static let legacyProduction = "dev.trellis"
    public let identifier: String
    /// The standardized `--state-directory`, when one was given.
    public let stateDirectory: String?
    /// An unbundled executable has no bundle identifier and is always a development build.
    public init(bundleIdentifier: String?, stateDirectory: URL? = nil) {
        identifier = bundleIdentifier ?? Self.development
        self.stateDirectory = stateDirectory?.standardizedFileURL.path
    }
    /// Names the instance's lock and activation notification.
    private var instanceKey: String {
        guard let stateDirectory else { return identifier }
        let digest = SHA256.hash(data: Data(stateDirectory.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(identifier).state-\(digest)"
    }
    public var isDevelopment: Bool { identifier != Self.production }
    public func lockURL(in directory: URL, uid: uid_t = getuid()) -> URL {
        directory.appendingPathComponent("\(instanceKey)-\(uid).instance.lock")
    }
    public var activationNotification: String { "\(instanceKey).activateExistingInstance" }
}
