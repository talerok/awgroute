// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "awgroute-helper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "awgroute-helper",
            path: "Sources/awgroute-helper"
        )
    ]
)
