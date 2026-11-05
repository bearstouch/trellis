// swift-tools-version: 5.9
// Two tree-sitter grammars, vendored unchanged except for this manifest: their upstream manifests add `scanner.c` only
// when `FileManager.fileExists("src/scanner.c")` is true, which SwiftPM doesn't evaluate from the package folder, so
// the scanner was left out and linking failed. Upstream C warnings are silenced (-w); the sources aren't ours to fix.
// See README.md for sources and versions.
import PackageDescription

let package = Package(
    name: "TreeSitterGrammars",
    products: [
        .library(name: "TreeSitterJavaScript", targets: ["TreeSitterJavaScript"]),
        .library(name: "TreeSitterYAML", targets: ["TreeSitterYAML"]),
    ],
    targets: [
        .target(
            name: "TreeSitterJavaScript", path: "JavaScript", exclude: ["LICENSE"], sources: ["src/parser.c", "src/scanner.c"],
            resources: [.copy("queries")], publicHeadersPath: "include", cSettings: [.headerSearchPath("src"), .unsafeFlags(["-w"])]),
        // scanner.c includes the schema.*.c files itself.
        .target(
            name: "TreeSitterYAML", path: "YAML", exclude: ["LICENSE", "src/schema.core.c", "src/schema.json.c", "src/schema.legacy.c"],
            sources: ["src/parser.c", "src/scanner.c"], resources: [.copy("queries")], publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src"), .unsafeFlags(["-w"])]),
    ],
    cLanguageStandard: .c11
)
