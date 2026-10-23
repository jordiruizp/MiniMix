// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniMixApp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MiniMix", targets: ["MiniMix"])
    ],
    dependencies: [
        .package(path: "../Packages/Core"),
        .package(path: "../Packages/Render"),
        .package(path: "../Packages/Media"),
        .package(path: "../Packages/Audio"),
        .package(path: "../Packages/Output"),
        .package(path: "../Packages/Persistence")
    ],
    targets: [
        .target(name: "MiniMixUI", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "CoreMocks", package: "Core"),
            .product(name: "Render", package: "Render"),
            .product(name: "Media", package: "Media"),
            .product(name: "Audio", package: "Audio"),
            .product(name: "Output", package: "Output"),
            .product(name: "Persistence", package: "Persistence")
        ]),
        .executableTarget(name: "MiniMix", dependencies: ["MiniMixUI"]),
        .testTarget(name: "MiniMixUITests", dependencies: ["MiniMixUI"])
    ]
)
