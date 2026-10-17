import Foundation

/// The app icon as a PNG, for `swift run` builds that have no `.app` bundle to carry `AppIcon.icns`.
public enum BundledAppIcon {
    public static func url() -> URL? {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return resources.url(forResource: "AppIcon", withExtension: "png", subdirectory: "AppIcon")
    }
}
