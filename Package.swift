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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "TrellisAskpass"),
        .executableTarget(name: "TrellisAskpassMain", dependencies: ["TrellisAskpass"]),
        .target(name: "TrellisCore", dependencies: ["TrellisAskpass"], resources: [.copy("Resources/Themes"), .copy("Resources/Fonts"), .copy("Resources/ShellIntegration"), .copy("Resources/AppIcon")]),
        .target(name: "TrellisPOSIX"),
        // The broker's resident code depends only on the POSIX shim: no Core resources, no engine.
        .target(name: "TrellisBroker", dependencies: ["TrellisPOSIX"]),
        .executableTarget(name: "TrellisBrokerMain", dependencies: ["TrellisBroker"]),
        .target(name: "TrellisTerminal", dependencies: ["TrellisCore", "TrellisPOSIX", "TrellisBroker", "SwiftTerm"]),
        .target(name: "TrellisControl", dependencies: ["TrellisCore"]),
        .target(name: "TrellisMCP", dependencies: ["TrellisControl", "TrellisCore"]),
        .target(name: "TrellisUI", dependencies: ["TrellisCore", "TrellisTerminal", "TrellisControl"]),
        .executableTarget(
            name: "TrellisApp", dependencies: ["TrellisUI", "TrellisTerminal", "TrellisControl", "TrellisMCP", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .target(name: "TrellisRelease"),
        .target(name: "TrellisCLI", dependencies: ["TrellisControl", "TrellisRelease"]),
        .executableTarget(name: "TrellisCLIMain", dependencies: ["TrellisCLI"]),
        .testTarget(name: "TrellisCoreTests", dependencies: ["TrellisCore", "TrellisAskpass"]),
        .testTarget(name: "TrellisUITests", dependencies: ["TrellisUI", "TrellisCore", "TrellisControl", "TrellisMCP", "TrellisAskpass"]),
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
