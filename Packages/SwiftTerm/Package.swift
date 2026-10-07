// swift-tools-version:5.9

import PackageDescription

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
let platformResources: [Resource] = []
#else
let platformExcludes: [String] = []
let platformResources: [Resource] = [.process("Apple/Metal/Shaders.metal")]
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftTerm",
            targets: ["SwiftTerm"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: platformExcludes + ["Mac/README.md"],
            resources: platformResources
        ),
    ],
    swiftLanguageVersions: [.v5]
)
