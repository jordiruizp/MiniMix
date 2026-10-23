// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "CoreMocks", targets: ["CoreMocks"])
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "CoreMocks", dependencies: ["Core"]),
        .testTarget(name: "CoreTests", dependencies: ["Core", "CoreMocks"])
    ]
)
