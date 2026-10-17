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
        .executable(name: "trellis-askpass", targets: ["TrellisAskpassMain"])
    ],
    dependencies: [
        .package(path: "ThirdParty/SwiftTerm")
    ],
    targets: [
        .target(name: "TrellisAskpass"),
        .executableTarget(name: "TrellisAskpassMain", dependencies: ["TrellisAskpass"]),
        .target(name: "TrellisCore", dependencies: ["TrellisAskpass"], resources: [.copy("Resources/Themes"), .copy("Resources/Fonts"), .copy("Resources/ShellIntegration")]),
        .target(name: "TrellisPOSIX"),
        .target(name: "TrellisTerminal", dependencies: ["TrellisCore", "TrellisPOSIX", "SwiftTerm"]),
        .target(name: "TrellisControl", dependencies: ["TrellisCore"]),
        .target(name: "TrellisMCP", dependencies: ["TrellisControl", "TrellisCore"]),
        .target(name: "TrellisUI", dependencies: ["TrellisCore", "TrellisTerminal", "TrellisControl"]),
        .executableTarget(name: "TrellisApp", dependencies: ["TrellisUI", "TrellisTerminal", "TrellisControl", "TrellisMCP"]),
        .target(name: "TrellisRelease"),
        .target(name: "TrellisCLI", dependencies: ["TrellisControl", "TrellisRelease"]),
        .executableTarget(name: "TrellisCLIMain", dependencies: ["TrellisCLI"]),
        .testTarget(name: "TrellisCoreTests", dependencies: ["TrellisCore", "TrellisAskpass"]),
        .testTarget(name: "TrellisUITests", dependencies: ["TrellisUI", "TrellisCore", "TrellisControl", "TrellisMCP", "TrellisAskpass"]),
        .testTarget(name: "TrellisTerminalTests", dependencies: ["TrellisTerminal"]),
        .testTarget(name: "TrellisControlTests", dependencies: ["TrellisControl", "TrellisCore"]),
        .testTarget(name: "TrellisMCPTests", dependencies: ["TrellisMCP", "TrellisControl", "TrellisCore"]),
        .testTarget(name: "TrellisCLITests", dependencies: ["TrellisCLI", "TrellisControl", "TrellisRelease"]),
        .testTarget(name: "TrellisReleaseTests", dependencies: ["TrellisRelease"])
    ],
    swiftLanguageModes: [.v6]
)
