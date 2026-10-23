// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Audio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Audio", targets: ["Audio"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "Audio", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "AudioTests", dependencies: ["Audio", .product(name: "CoreMocks", package: "Core")])
    ]
)
