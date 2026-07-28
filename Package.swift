// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Banyan",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Banyan", targets: ["Banyan"]),
        .executable(name: "banyanctl", targets: ["BanyanCtl"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0")
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "BanyanCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "Banyan",
            dependencies: [
                "BanyanCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "BanyanCtl",
            dependencies: ["BanyanCore"]
        ),
        .testTarget(
            name: "BanyanCoreTests",
            dependencies: ["BanyanCore"]
        ),
        .testTarget(
            name: "BanyanTests",
            dependencies: ["Banyan"]
        )
    ],
    swiftLanguageModes: [.v5]
)
