// swift-tools-version: 6.0
import PackageDescription

// Harness de estrés y medición (H · T61). Ejecutable: `minimix-stress`.
let package = Package(
    name: "StressHarness",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "minimix-stress", targets: ["minimix-stress"]),
        .library(name: "StressHarnessKit", targets: ["StressHarnessKit"])
    ],
    dependencies: [
        .package(path: "../../Packages/Core"),
        .package(path: "../../Packages/Render"),
        .package(path: "../../Tests")
    ],
    targets: [
        .target(name: "StressHarnessKit", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "CoreMocks", package: "Core"),
            .product(name: "Render", package: "Render"),
            .product(name: "TestSupport", package: "Tests")
        ]),
        .executableTarget(name: "minimix-stress", dependencies: ["StressHarnessKit"]),
        .testTarget(name: "StressHarnessTests", dependencies: ["StressHarnessKit"])
    ]
)
