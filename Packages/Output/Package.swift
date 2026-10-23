// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Output",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Output", targets: ["Output"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Render")
    ],
    targets: [
        .target(name: "Output", dependencies: [.product(name: "Core", package: "Core"), .product(name: "Render", package: "Render")]),
        .testTarget(name: "OutputTests", dependencies: ["Output", .product(name: "CoreMocks", package: "Core")])
    ]
)
