// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PuckSwift", platforms: [.macOS(.v14)], products: [
    .library(name: "PuckSwift", targets: ["PuckSwift"]),
    .executable(name: "puck-swift-example", targets: ["PuckSwiftExample"])
], targets: [.target(name: "PuckSwift"), .executableTarget(name: "PuckSwiftExample", dependencies: ["PuckSwift"]),
    .testTarget(name: "PuckSwiftTests", dependencies: ["PuckSwift"])], swiftLanguageModes: [.v5])
