import Foundation

/// Пользовательские правила роутинга.
///
/// Внутри — секция `route` конфига backend'а плюс необязательная секция `dns`.
/// Домен намеренно не разбирает их структуру: это словарь backend'а, и его схема
/// меняется вместе с backend'ом. Домен знает ровно две вещи — что текст обязан быть
/// валидным JSON-объектом и что `dns` живёт отдельно от `route`.
public struct RoutingRules: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public static let empty = RoutingRules(text: """
    {
      "rules": [],
      "final": "vpn"
    }
    """)
}

/// Результат проверки правил — для индикатора в редакторе.
public enum RulesValidation: Equatable, Sendable {
    case ok
    case invalid(String)

    public var isValid: Bool { self == .ok }
}
