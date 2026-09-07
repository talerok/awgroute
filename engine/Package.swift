// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "awgroute-engine",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Контракт с GUI: версия протокола, команды, события, пути.
        .package(path: "../shared")
    ],
    targets: [
        .executableTarget(
            name: "awgroute-engine",
            dependencies: [.product(name: "AwgProtocol", package: "shared")],
            path: "Sources/awgroute-engine"
        )
    ]
)
