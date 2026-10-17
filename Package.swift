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
        .executable(name: "Trellis", targets: ["TrellisApp"]),
        // Installed as `trellis` by packaging; a distinct build name avoids
        // colliding with the app binary on case-insensitive volumes.
        .executable(name: "trellis-cli", targets: ["TrellisCLIMain"])
    ],
    dependencies: [
        .package(path: "ThirdParty/SwiftTerm")
    ],
    targets: [
        .target(name: "TrellisCore", resources: [.copy("Resources/Themes"), .copy("Resources/Fonts"), .copy("Resources/ShellIntegration")]),
        .target(name: "TrellisPOSIX"),
        .target(name: "TrellisTerminal", dependencies: ["TrellisCore", "TrellisPOSIX", "SwiftTerm"]),
        .target(name: "TrellisControl", dependencies: ["TrellisCore"]),
        .target(name: "TrellisUI", dependencies: ["TrellisCore", "TrellisTerminal", "TrellisControl"]),
        .executableTarget(name: "TrellisApp", dependencies: ["TrellisUI", "TrellisTerminal", "TrellisControl"]),
        .target(name: "TrellisRelease"),
        .target(name: "TrellisCLI", dependencies: ["TrellisControl", "TrellisRelease"]),
        .executableTarget(name: "TrellisCLIMain", dependencies: ["TrellisCLI"]),
        .testTarget(name: "TrellisCoreTests", dependencies: ["TrellisCore"]),
        .testTarget(name: "TrellisUITests", dependencies: ["TrellisUI", "TrellisCore", "TrellisControl"]),
        .testTarget(name: "TrellisTerminalTests", dependencies: ["TrellisTerminal"]),
        .testTarget(name: "TrellisControlTests", dependencies: ["TrellisControl", "TrellisCore"]),
        .testTarget(name: "TrellisCLITests", dependencies: ["TrellisCLI", "TrellisControl", "TrellisRelease"]),
        .testTarget(name: "TrellisReleaseTests", dependencies: ["TrellisRelease"])
    ],
    swiftLanguageModes: [.v6]
)
