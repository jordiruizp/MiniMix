// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniMixIntegration",
    platforms: [.macOS(.v15)],
    products: [
        // Lo usa también Tools/StressHarness (medidor de memoria/CPU, metadatos de máquina).
        .library(name: "TestSupport", targets: ["TestSupport"])
    ],
    dependencies: [
        .package(path: "../Packages/Core"),
        .package(path: "../Packages/Render"),
        .package(path: "../Packages/Media"),
        .package(path: "../Packages/Audio")
    ],
    targets: [
        .target(name: "TestSupport", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "IntegrationTests", dependencies: [
            "TestSupport",
            .product(name: "Core", package: "Core"),
            .product(name: "CoreMocks", package: "Core"),
            .product(name: "Render", package: "Render"),
            .product(name: "Media", package: "Media"),
            .product(name: "Audio", package: "Audio")
        ])
    ]
)
