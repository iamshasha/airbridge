// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AirBridge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AirBridgeCore", targets: ["AirBridgeCore"]),
        .executable(name: "AirBridge", targets: ["AirBridge"]),
        .executable(name: "airbridge-cli", targets: ["airbridge-cli"]),
    ],
    targets: [
        .target(name: "AirBridgeCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "AirBridge", dependencies: ["AirBridgeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "airbridge-cli", dependencies: ["AirBridgeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AirBridgeCoreTests", dependencies: ["AirBridgeCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
