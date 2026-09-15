// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftOSLogger",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftOSLogger", targets: ["SwiftOSLogger"]),
    ],
    targets: [
        .target(
            name: "SwiftOSLogger",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "SwiftOSLoggerTests",
            dependencies: ["SwiftOSLogger"]
        ),
    ]
)
