// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "uTerm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UTermCore", targets: ["UTermCore"]),
        .library(name: "UTermTerminal", targets: ["UTermTerminal"]),
        .library(name: "UTermUI", targets: ["UTermUI"]),
        .executable(name: "uTerm", targets: ["UTermApp"])
    ],
    dependencies: [
        .package(path: "ThirdParty/SwiftTerm")
    ],
    targets: [
        .target(name: "UTermCore"),
        .target(name: "UTermPOSIX"),
        .target(name: "UTermTerminal", dependencies: ["UTermCore", "UTermPOSIX", "SwiftTerm"]),
        .target(name: "UTermUI", dependencies: ["UTermCore", "UTermTerminal"]),
        .executableTarget(name: "UTermApp", dependencies: ["UTermUI"]),
        .testTarget(name: "UTermCoreTests", dependencies: ["UTermCore"]),
        .testTarget(name: "UTermUITests", dependencies: ["UTermUI", "UTermCore"]),
        .testTarget(name: "UTermTerminalTests", dependencies: ["UTermTerminal"])
    ],
    swiftLanguageModes: [.v6]
)
