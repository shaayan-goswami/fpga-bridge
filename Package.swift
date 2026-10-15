// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fpga-bridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FPGABridgeCore", targets: ["FPGABridgeCore"]),
        .executable(name: "fpga-bridge", targets: ["fpga-bridge"]),
        .executable(name: "FPGA Bridge", targets: ["FPGABridgeApp"]),
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
            // The .icon is compiled into the .app by scripts/make-app.sh (actool); the previews are for in-app use.
            exclude: ["Resources/AppIcon.icon"],
            resources: [
                .copy("Resources/AppIcon-Default.png"), .copy("Resources/AppIcon-Dark.png"),
                .copy("Resources/AppIcon-ClearLight.png"), .copy("Resources/AppIcon-ClearDark.png"),
            ]
        ),
        .testTarget(name: "FPGABridgeAppTests", dependencies: ["FPGABridgeApp", "FPGABridgeCore"]),
        .testTarget(
            name: "FPGABridgeCoreTests",
            dependencies: ["FPGABridgeCore"],
            resources: [.copy("Fixtures"), .copy("FakeRemote")]
        ),
    ]
)
