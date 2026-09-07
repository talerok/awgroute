import Foundation
import AwgDomain

/// Редактируемые правила роутинга.
///
/// Содержимое — секция `route` конфига backend'а плюс необязательная `dns`.
/// Валидация считается один раз на изменение текста, а не на каждый рендер SwiftUI.
@MainActor
public final class RulesStore: ObservableObject {

    @Published public var text: String {
        didSet { validation = renderer.validate(rules: RoutingRules(text: text)) }
    }
    @Published public private(set) var validation: RulesValidation

    private let repository: RulesRepository
    private let renderer: ConfigRendering

    public init(repository: RulesRepository, renderer: ConfigRendering) {
        self.repository = repository
        self.renderer = renderer
        let loaded = repository.load().text
        self.text = loaded
        self.validation = renderer.validate(rules: RoutingRules(text: loaded))
    }

    public enum SaveError: Error, LocalizedError {
        case invalidJSON(String)
        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail): return "Rules are not valid JSON: \(detail)"
            }
        }
    }

    public func save() throws {
        if case .invalid(let detail) = validation {
            // Своя ошибка, а не TunnelError: редактор правил не про туннель,
            // и смешивать словари слоёв незачем.
            throw SaveError.invalidJSON(detail)
        }
        try repository.save(RoutingRules(text: text))
    }

    public func revert() { text = repository.load().text }

    public func format() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: pretty, encoding: .utf8) else { return }
        text = s
    }

    // MARK: - Пресеты

    public struct Preset: Identifiable, Equatable {
        public var id: String { name }
        let name: String
        let resourceName: String
    }

    static let presets: [Preset] = [
        .init(name: "Empty",            resourceName: "empty"),
        .init(name: "RU routing",       resourceName: "ru-routing"),
        .init(name: "Ad blocking",      resourceName: "ad-blocking"),
        .init(name: "Full Clash-style", resourceName: "full-clash-style"),
    ]

    public func load(preset: Preset) {
        guard let url = Bundle.main.url(forResource: preset.resourceName, withExtension: "json",
                                        subdirectory: "rule-presets")
            ?? Bundle.main.url(forResource: preset.resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else { return }
        text = s
    }
}
