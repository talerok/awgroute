// swift-tools-version: 5.9
import PackageDescription

// Слои и направление зависимостей:
//
//   AwgDomain   — сущности, порты, сценарии. Ни от чего не зависит.
//        ▲
//   AwgConfig   — адаптер конфигов: .conf → сущность, сущность → JSON backend'а.
//        ▲
//   awgconfgen  — CLI поверх обоих, для отладки без GUI.
//
// Приложение (Xcode-таргет) линкует оба и добавляет свои адаптеры: helper, Keychain,
// файловые хранилища, логи. Стрелки всегда указывают внутрь, на домен.
let package = Package(
    name: "AwgRouteShared",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AwgDomain", targets: ["AwgDomain"]),
        .library(name: "AwgProtocol", targets: ["AwgProtocol"]),
        .library(name: "AwgConfig", targets: ["AwgConfig"]),
        .executable(name: "awgconfgen", targets: ["awgconfgen"]),
    ],
    targets: [
        .target(
            name: "AwgDomain",
            path: "Sources/AwgDomain"
        ),
        // Контракт app ⇄ helper. Намеренно без зависимостей: линкуется в оба модуля.
        .target(
            name: "AwgProtocol",
            path: "Sources/AwgProtocol"
        ),
        .target(
            name: "AwgConfig",
            dependencies: ["AwgDomain"],
            path: "Sources/AwgConfig"
        ),
        .executableTarget(
            name: "awgconfgen",
            dependencies: ["AwgDomain", "AwgConfig"],
            path: "Sources/awgconfgen"
        ),
        .testTarget(
            name: "AwgDomainTests",
            dependencies: ["AwgDomain"],
            path: "Tests/AwgDomainTests"
        ),
        .testTarget(
            name: "AwgConfigTests",
            dependencies: ["AwgDomain", "AwgConfig"],
            path: "Tests/AwgConfigTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
