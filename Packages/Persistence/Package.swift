// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Persistence", targets: ["Persistence"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(name: "Persistence", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", .product(name: "CoreMocks", package: "Core")])
    ]
)
