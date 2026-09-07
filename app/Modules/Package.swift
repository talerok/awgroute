// swift-tools-version: 5.9
import PackageDescription

// Слои приложения как отдельные таргеты — чтобы направление зависимостей проверял
// компилятор, а не соглашение о папках.
//
//   AwgPresentation ──► AwgDomain ◄── AwgInfrastructure
//
// AwgPresentation НЕ зависит от AwgInfrastructure: попытка дёрнуть Keychain, сокет
// или путь на диске из вью теперь не соберётся. Обратное тоже верно — инфраструктура
// не видит UI-store'ов. Раньше и то и другое было нарушено, и ловилось только греппом.
let package = Package(
    name: "AwgApp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AwgInfrastructure", targets: ["AwgInfrastructure"]),
        .library(name: "AwgPresentation", targets: ["AwgPresentation"]),
    ],
    dependencies: [
        .package(path: "../../shared")
    ],
    targets: [
        .target(
            name: "AwgInfrastructure",
            dependencies: [
                .product(name: "AwgDomain", package: "shared"),
                .product(name: "AwgConfig", package: "shared"),
                .product(name: "AwgProtocol", package: "shared"),
            ],
            path: "Sources/AwgInfrastructure"
        ),
        .testTarget(
            name: "AwgAppTests",
            dependencies: ["AwgInfrastructure", "AwgPresentation"],
            path: "Tests/AwgAppTests"
        ),
        .target(
            name: "AwgPresentation",
            // Намеренно только домен.
            dependencies: [.product(name: "AwgDomain", package: "shared")],
            path: "Sources/AwgPresentation"
        ),
    ]
)
