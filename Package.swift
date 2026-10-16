// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "uTerm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UTermCore", targets: ["UTermCore"]),
        .library(name: "UTermTerminal", targets: ["UTermTerminal"]),
        .executable(name: "uTerm", targets: ["UTermApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(name: "UTermCore"),
        .target(name: "UTermPOSIX"),
        .target(name: "UTermTerminal", dependencies: ["UTermCore", "UTermPOSIX", "SwiftTerm"]),
        .executableTarget(name: "UTermApp", dependencies: ["UTermTerminal"]),
        .testTarget(name: "UTermCoreTests", dependencies: ["UTermCore"]),
        .testTarget(name: "UTermTerminalTests", dependencies: ["UTermTerminal"])
    ],
    swiftLanguageModes: [.v6]
)
