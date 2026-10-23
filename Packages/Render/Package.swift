// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Render",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Render", targets: ["Render"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "Render", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "RenderTests", dependencies: ["Render", .product(name: "CoreMocks", package: "Core")])
    ]
)
