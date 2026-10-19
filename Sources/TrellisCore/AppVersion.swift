import Foundation

/// The product version. Packaged builds read it from Info.plist; SwiftPM builds have no bundle plist, so they fall
/// back to `release`, which a test keeps equal to `release/manifest.json`.
public enum AppVersion {
    public static let release = "0.11.0"
    public static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? release }
}
