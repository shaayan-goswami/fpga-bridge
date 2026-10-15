// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fpga-bridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FPGABridgeCore", targets: ["FPGABridgeCore"]),
        .executable(name: "fpga-bridge", targets: ["fpga-bridge"]),
        .executable(name: "FPGABridgeApp", targets: ["FPGABridgeApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "FPGABridgeCore"),
        .executableTarget(
            name: "fpga-bridge",
            dependencies: [
                "FPGABridgeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "FPGABridgeApp",
            dependencies: ["FPGABridgeCore"],
            exclude: ["Resources/AppIcon.icns"],
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(
            name: "FPGABridgeCoreTests",
            dependencies: ["FPGABridgeCore"],
            resources: [.copy("Fixtures"), .copy("FakeRemote")]
        ),
    ]
)
