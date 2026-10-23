import Foundation

/// The product version. Packaged builds read it from Info.plist; SwiftPM builds have no bundle plist, so they fall
/// back to `release`, which a test keeps equal to `release/manifest.json`.
public enum AppVersion {
    public static let release = "1.0.0-beta.1"
    public static var current: String { bundled ?? release }
    /// A packaged build's full version. `CFBundleShortVersionString` must be numeric (`1.0.0`), so packaging also writes
    /// the whole version, pre-release label included, to `TrellisVersion`. Nil for SwiftPM builds.
    public static var bundled: String? {
        let info = Bundle.main.infoDictionary
        return info?["TrellisVersion"] as? String ?? info?["CFBundleShortVersionString"] as? String
    }
}
