// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Media",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Media", targets: ["Media"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Render")
    ],
    targets: [
        .target(name: "Media", dependencies: [.product(name: "Core", package: "Core"), .product(name: "Render", package: "Render")]),
        .testTarget(name: "MediaTests", dependencies: ["Media", .product(name: "CoreMocks", package: "Core")])
    ]
)
