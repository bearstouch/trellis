import Foundation

public enum ThemeExample: String, CaseIterable, Sendable { case minimal, light, dark }

public enum ThemeExamples {
    public static func data(_ example: ThemeExample) throws -> Data {
        // SwiftPM's generated lookup uses the .app root and an absolute build
        // path. Native app resources live in Contents/Resources instead.
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Trellis_TrellisCore.bundle")
        let resources = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = resources.url(forResource: "example-\(example.rawValue).theme", withExtension: "json", subdirectory: "Themes") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
