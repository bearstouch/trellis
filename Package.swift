// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trellis",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrellisCore", targets: ["TrellisCore"]),
        .library(name: "TrellisTerminal", targets: ["TrellisTerminal"]),
        .library(name: "TrellisUI", targets: ["TrellisUI"]),
        .library(name: "TrellisControl", targets: ["TrellisControl"]),
        .library(name: "TrellisMCP", targets: ["TrellisMCP"]),
        .executable(name: "Trellis", targets: ["TrellisApp"]),
        // Installed as `trellis` by packaging; a distinct build name avoids
        // colliding with the app binary on case-insensitive volumes.
        .executable(name: "trellis-cli", targets: ["TrellisCLIMain"]),
        // SSH_ASKPASS helper for saved-host passwords; bundled beside the app binary.
        .executable(name: "trellis-askpass", targets: ["TrellisAskpassMain"]),
        // Opt-in session broker that keeps sessions running after quit (FR-R03); bundled beside the app binary.
        .executable(name: "trellis-broker", targets: ["TrellisBrokerMain"])
    ],
    dependencies: [
        .package(path: "ThirdParty/SwiftTerm"),
        // MAC-14: in-place updates. Linked only by the app target; packaging embeds Sparkle.framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        // FR-TD11: tree-sitter highlighting for the tool dock's editor, used only by TrellisHighlight. Neon has no
        // recent tag and pulls SwiftTreeSitter's main branch, so both are pinned by revision; the Swift grammar's
        // generated parser exists only on its with-generated-files branch.
        .package(url: "https://github.com/ChimeHQ/Neon", revision: "38cf4a6a05a6aa1e038b65a16f773c77d4145efc"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", revision: "82bb3a533e0801fd2bbaa11dc49676e10bf41948"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
        // JavaScript and YAML, vendored because their manifests drop scanner.c (see its README).
        .package(path: "ThirdParty/TreeSitterGrammars")
    ],
    targets: [
        .target(name: "TrellisAskpass"),
        .executableTarget(name: "TrellisAskpassMain", dependencies: ["TrellisAskpass"]),
        .target(name: "TrellisCore", dependencies: ["TrellisAskpass"], resources: [.copy("Resources/Themes"), .copy("Resources/Fonts"), .copy("Resources/ShellIntegration"), .copy("Resources/AppIcon"), .copy("Resources/SettingsIcons"), .copy("Resources/Agents")]),
        .target(name: "TrellisPOSIX"),
        // The broker's resident code depends only on the POSIX shim: no Core resources, no engine.
        .target(name: "TrellisBroker", dependencies: ["TrellisPOSIX"]),
        .executableTarget(name: "TrellisBrokerMain", dependencies: ["TrellisBroker"]),
        .target(name: "TrellisTerminal", dependencies: ["TrellisCore", "TrellisPOSIX", "TrellisBroker", "SwiftTerm"]),
        .target(name: "TrellisControl", dependencies: ["TrellisCore"]),
        .target(name: "TrellisMCP", dependencies: ["TrellisControl", "TrellisCore"]),
        // The only module that imports Neon, SwiftTreeSitter and the grammars.
        .target(
            name: "TrellisHighlight",
            dependencies: [
                "TrellisCore", .product(name: "Neon", package: "Neon"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"), .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"), .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"), .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterJavaScript", package: "TreeSitterGrammars"), .product(name: "TreeSitterYAML", package: "TreeSitterGrammars"),
            ]),
        .target(name: "TrellisUI", dependencies: ["TrellisCore", "TrellisTerminal", "TrellisControl", "TrellisHighlight"]),
        .executableTarget(
            name: "TrellisApp", dependencies: ["TrellisUI", "TrellisTerminal", "TrellisControl", "TrellisMCP", "TrellisRelease", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .target(name: "TrellisRelease"),
        .target(name: "TrellisCLI", dependencies: ["TrellisControl", "TrellisCore", "TrellisRelease"]),
        .executableTarget(name: "TrellisCLIMain", dependencies: ["TrellisCLI"]),
        .testTarget(name: "TrellisCoreTests", dependencies: ["TrellisCore", "TrellisAskpass"]),
        .testTarget(name: "TrellisUITests", dependencies: ["TrellisUI", "TrellisCore", "TrellisControl", "TrellisMCP", "TrellisAskpass"]),
        .testTarget(name: "TrellisHighlightTests", dependencies: ["TrellisHighlight", "TrellisCore"]),
        .testTarget(name: "TrellisTerminalTests", dependencies: ["TrellisTerminal"]),
        .testTarget(name: "TrellisControlTests", dependencies: ["TrellisControl", "TrellisCore"]),
        .testTarget(name: "TrellisMCPTests", dependencies: ["TrellisMCP", "TrellisControl", "TrellisCore"]),
        .testTarget(name: "TrellisCLITests", dependencies: ["TrellisCLI", "TrellisControl", "TrellisRelease"]),
        .testTarget(name: "TrellisReleaseTests", dependencies: ["TrellisRelease"]),
        .testTarget(name: "TrellisBrokerTests", dependencies: ["TrellisBroker", "TrellisPOSIX"])
    ],
    swiftLanguageModes: [.v6]
)

#if os(Linux)
// Linux builds only the remote helper (FR-RW02) and its tests (`scripts/test-linux.sh`).
let linuxTargets: Set<String> = ["TrellisPOSIX", "TrellisBroker", "TrellisBrokerMain", "TrellisBrokerTests"]
package.products = [.executable(name: "trellis-broker", targets: ["TrellisBrokerMain"])]
package.dependencies = []
package.targets = package.targets.filter { linuxTargets.contains($0.name) }
#endif
