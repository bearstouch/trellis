import Foundation

/// Editor-inspired palettes shipped with the app; reserved IDs keep them immutable.
public enum BundledThemes {
    public static let families = ["modern", "one", "monokai", "solarized", "nord", "dracula", "github", "tokyo", "gruvbox", "rose-pine"]

    public static func documents() throws -> [ThemeDocument] {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        return try families.flatMap { family in
            try ThemeAppearance.allCases.map { appearance in
                let id = "trellis-\(family)-\(appearance.rawValue)"
                guard let url = resources.url(forResource: id + ".theme", withExtension: "json", subdirectory: "Themes") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return try ThemeValidator.validate(Data(contentsOf: url))
            }
        }
    }

    public static let all: [ResolvedTheme] = {
        // A damaged resource bundle still leaves the original Trellis defaults usable.
        let palettes = (try? documents()) ?? []
        return ThemeAppearance.allCases.map(ResolvedTheme.builtIn) + palettes.map { $0.resolved() }
    }()

    public static func theme(_ id: String) -> ResolvedTheme? { all.first { $0.id == id } }
}
