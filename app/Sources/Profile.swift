import Foundation
import AwgConfig

/// Сохранённый VPN-профиль. На диске лежит как
/// `~/Library/Application Support/AwgRoute/profiles/<id>.json`.
///
/// **Секреты в JSON не пишутся.** `config.interface.privateKey` и
/// `config.peers[].presharedKey` всегда пустые строки. Реальные ключи
/// лежат в Keychain под аккаунтами `interface-pk-<id>` и `peer-psk-<id>-<peerIdx>`.
struct Profile: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var notes: String
    let createdAt: Date
    /// Полный AwgConfig с **пустыми** секретами.
    var config: AwgConfig

    /// Маскированное представление приватного ключа: `aGVs…NDU2`
    var maskedPrivateKey: String { Profile.mask(config.interface.privateKey.isEmpty ? "(stored in Keychain)" : config.interface.privateKey) }

    static func mask(_ s: String) -> String {
        guard s.count > 10 else { return String(repeating: "•", count: max(s.count, 4)) }
        let prefix = s.prefix(4)
        let suffix = s.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
