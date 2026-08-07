// swift-tools-version: 6.3

import PackageDescription

var packageProducts: [Product] = [
        .executable(name: "banyanctl", targets: ["BanyanCtl"]),
        .executable(name: "BanyanTUI", targets: ["BanyanTUI"])
]

var packageTargets: [Target] = [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "BanyanCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "BanyanCtl",
            dependencies: ["BanyanCore"]
        ),
        .executableTarget(
            name: "BanyanTUI",
            dependencies: ["BanyanCore"]
        ),
        .testTarget(
            name: "BanyanCoreTests",
            dependencies: ["BanyanCore"]
        ),
        .testTarget(
            name: "BanyanTUITests",
            dependencies: ["BanyanTUI"]
        )
]

#if os(macOS)
packageProducts.append(.executable(name: "Banyan", targets: ["Banyan"]))
packageTargets.append(contentsOf: [
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
    .testTarget(
        name: "BanyanTests",
        dependencies: ["Banyan"]
    )
])
#endif

let package = Package(
    name: "Banyan",
    platforms: [
        .macOS(.v14)
    ],
    products: packageProducts,
    dependencies: [
        .package(path: "Packages/SwiftTerm")
    ],
    targets: packageTargets,
    swiftLanguageModes: [.v5]
)
