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
        .executable(name: "Trellis", targets: ["TrellisApp"])
    ],
    dependencies: [
        .package(path: "ThirdParty/SwiftTerm")
    ],
    targets: [
        .target(name: "TrellisCore", resources: [.copy("Resources/Themes")]),
        .target(name: "TrellisPOSIX"),
        .target(name: "TrellisTerminal", dependencies: ["TrellisCore", "TrellisPOSIX", "SwiftTerm"]),
        .target(name: "TrellisControl", dependencies: ["TrellisCore"]),
        .target(name: "TrellisUI", dependencies: ["TrellisCore", "TrellisTerminal"]),
        .executableTarget(name: "TrellisApp", dependencies: ["TrellisUI", "TrellisControl"]),
        .testTarget(name: "TrellisCoreTests", dependencies: ["TrellisCore"]),
        .testTarget(name: "TrellisUITests", dependencies: ["TrellisUI", "TrellisCore"]),
        .testTarget(name: "TrellisTerminalTests", dependencies: ["TrellisTerminal"]),
        .testTarget(name: "TrellisControlTests", dependencies: ["TrellisControl"])
    ],
    swiftLanguageModes: [.v6]
)
