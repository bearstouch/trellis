import Foundation

/// A Settings sidebar icon, as a PNG generated from `Design/SettingsIcons` by `scripts/generate-settings-icons.sh`.
public enum BundledSettingsIcon: String, CaseIterable, Sendable {
    case appearance, sessions, broker, keyboard, themes, agents, automation, remote, updates

    public var url: URL? {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return resources.url(forResource: rawValue, withExtension: "png", subdirectory: "SettingsIcons")
    }
}
