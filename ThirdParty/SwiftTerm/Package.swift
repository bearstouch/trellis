// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", exclude: ["Mac/README.md"],
        resources: [.process("Apple/Metal/Shaders.metal")])],
    swiftLanguageModes: [.v5]
)
