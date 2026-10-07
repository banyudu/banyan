// swift-tools-version: 6.3

import PackageDescription

var packageProducts: [Product] = [
        .executable(name: "banyanctl", targets: ["BanyanCtl"]),
        .executable(name: "BanyanTUI", targets: ["BanyanTUI"])
]

var packageTargets: [Target] = [
        .target(name: "CTerminalPTY", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "BanyanCore",
            dependencies: ["CSQLite", "CTerminalPTY"]
        ),
        .executableTarget(
            name: "BanyanCtl",
            dependencies: ["BanyanCore"]
        ),
        .executableTarget(
            name: "BanyanTUI",
            dependencies: ["BanyanCore", "CTerminalPTY", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(
            name: "BanyanCtlTests",
            dependencies: ["BanyanCtl"]
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
    ),
    // A/B harness for the terminal renderer experiment; see
    // docs/terminal-renderer-experiment.md.
    .executableTarget(
        name: "TerminalRenderBench",
        dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm")
        ]
    )
])
packageProducts.append(.executable(name: "TerminalRenderBench", targets: ["TerminalRenderBench"]))
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
