import Foundation

/// A packaged build's Sparkle feed (MAC-14). Builds without one have no updater and never contact the network.
public struct UpdateFeed: Equatable, Sendable {
    public static let betaChannel = "beta"
    public let url: URL
    public let publicKey: String

    /// Needs an HTTPS `SUFeedURL` (plain HTTP only on loopback, for local testing) and a non-empty `SUPublicEDKey`.
    public init?(info: [String: Any]) {
        guard let raw = info["SUFeedURL"] as? String, let url = URL(string: raw), let host = url.host, !host.isEmpty,
            let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces), !key.isEmpty
        else { return nil }
        guard url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else { return nil }
        self.url = url; publicKey = key
    }
}

/// Update choices Sparkle doesn't store itself. Automatic checks live in Sparkle's own defaults, off until turned on.
public struct UpdatePreferences {
    public static let includeBetasKey = "TrellisIncludeBetaUpdates"
    private let defaults: UserDefaults
    private let version: String
    public init(defaults: UserDefaults = .standard, version: String = AppVersion.current) { self.defaults = defaults; self.version = version }

    /// Unset means "follow the running build": a pre-release keeps receiving pre-releases.
    public var includeBetas: Bool {
        get { defaults.object(forKey: Self.includeBetasKey) as? Bool ?? AppVersion.isPrerelease(version) }
        nonmutating set { defaults.set(newValue, forKey: Self.includeBetasKey) }
    }
    /// Items without a channel are stable and always allowed; `beta` items need the opt-in.
    public var allowedChannels: Set<String> { includeBetas ? [UpdateFeed.betaChannel] : [] }
}
