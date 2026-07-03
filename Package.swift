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
        .executableTarget(
            name: "Banyan",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .executableTarget(
            name: "BanyanCtl"
        )
    ],
    swiftLanguageModes: [.v5]
)
