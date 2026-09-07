import Foundation

/// Сохранённый VPN-профиль.
///
/// Сущность домена: не знает, где и как хранится. Тем, что профиль лежит файлом в
/// Application Support, а секреты — в Keychain, занимается адаптер `ProfileRepository`.
///
/// **Секреты в профиле не хранятся.** `config.interface.privateKey` и
/// `config.peers[].presharedKey` содержат `Profile.secretPlaceholder`, а настоящие
/// значения живут в `SecretStore`.
public struct Profile: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var notes: String
    public let createdAt: Date
    /// Полный AwgConfig с подставленными вместо секретов плейсхолдерами.
    public var config: AwgConfig

    public init(id: UUID, name: String, notes: String = "", createdAt: Date, config: AwgConfig) {
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.config = config
    }

    /// Значение-заглушка на месте секрета: «настоящее лежит в SecretStore».
    /// Часть контракта домена, а не деталь хранилища: по нему `MaterializeProfile`
    /// понимает, что нужно сходить за секретом.
    public static let secretPlaceholder = "<keychain-ref>"

    /// Маскированное представление приватного ключа для UI.
    public var maskedPrivateKey: String {
        let pk = config.interface.privateKey
        if pk.isEmpty || pk == Self.secretPlaceholder { return "(stored in Keychain)" }
        return Self.mask(pk)
    }

    public static func mask(_ s: String) -> String {
        guard s.count > 10 else { return String(repeating: "•", count: max(s.count, 4)) }
        return "\(s.prefix(4))…\(s.suffix(4))"
    }
}
