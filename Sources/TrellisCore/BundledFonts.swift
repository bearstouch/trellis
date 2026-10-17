import Foundation

/// Terminal typefaces shipped with the app so the default never depends on installed fonts.
public enum BundledFonts {
    /// File stems; each family ships Regular, Bold, Italic and Bold Italic plus `<family>-OFL.txt`.
    public static let families = ["RobotoMono", "JetBrainsMono", "CascadiaMonoNF", "IBMPlexMono", "IosevkaFixed", "AtkinsonHyperlegibleMono"]
    public static let styles = ["Regular", "Bold", "Italic", "BoldItalic"]
    public static let faces = families.flatMap { family in styles.map { "\(family)-\($0)" } }

    public static func licenseName(for family: String) -> String {
        "\(family.hasSuffix("NF") ? String(family.dropLast(2)) : family)-OFL"
    }

    public static func urls() -> [URL] {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return faces.compactMap { resources.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts") }
    }
}
