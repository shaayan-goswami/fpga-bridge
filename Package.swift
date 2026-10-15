// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fpga-bridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FPGABridgeCore", targets: ["FPGABridgeCore"]),
        .executable(name: "fpga-bridge", targets: ["fpga-bridge"]),
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
        .testTarget(name: "FPGABridgeCoreTests", dependencies: ["FPGABridgeCore"]),
    ]
)
