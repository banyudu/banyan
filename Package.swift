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
        .target(
            name: "BanyanCore"
        ),
        .executableTarget(
            name: "Banyan",
            dependencies: [
                "BanyanCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .executableTarget(
            name: "BanyanCtl",
            dependencies: ["BanyanCore"]
        ),
        .testTarget(
            name: "BanyanCoreTests",
            dependencies: ["BanyanCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
