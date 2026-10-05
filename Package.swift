// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AirUltrawide",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge"
        ),
        .executableTarget(
            name: "AirUltrawide",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "Sources/AirUltrawide",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
