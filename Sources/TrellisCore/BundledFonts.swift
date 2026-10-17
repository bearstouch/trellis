import Foundation

/// Terminal typefaces shipped with the app so the default never depends on installed fonts.
public enum BundledFonts {
    public static let faces = ["RobotoMono-Regular", "RobotoMono-Bold", "RobotoMono-Italic", "RobotoMono-BoldItalic"]

    public static func urls() -> [URL] {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return faces.compactMap { resources.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts") }
    }
}
