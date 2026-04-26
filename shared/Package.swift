// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwgRouteShared",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AwgConfig", targets: ["AwgConfig"]),
        .executable(name: "awgconfgen", targets: ["awgconfgen"]),
    ],
    targets: [
        .target(
            name: "AwgConfig",
            path: "Sources/AwgConfig"
        ),
        .executableTarget(
            name: "awgconfgen",
            dependencies: ["AwgConfig"],
            path: "Sources/awgconfgen"
        ),
        .testTarget(
            name: "AwgConfigTests",
            dependencies: ["AwgConfig"],
            path: "Tests/AwgConfigTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
