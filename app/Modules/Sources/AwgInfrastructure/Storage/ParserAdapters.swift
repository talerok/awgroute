import Foundation
import AwgDomain
import AwgConfig

/// Реализация `ConfigParsing` — тонкая обёртка над парсером `.conf`.
/// Существует, чтобы домен не зависел от модуля разбора конфигов.
public struct AwgConfigParserAdapter: ConfigParsing {
    public init() {}

    public func parse(_ text: String) throws -> (config: AwgConfig, warnings: [String]) {
        let parsed = try AwgConfigParser.parse(text)
        return (parsed, parsed.warnings)
    }
}

/// Реализация `BackendAvailability`.
public struct BundledBackendAvailability: BackendAvailability {
    public init() {}

    public var isBackendPresent: Bool { BackendBinary.locate() != nil }
}
