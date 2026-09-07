import Foundation

/// Подставляет в профиль настоящие секреты из `SecretStore`.
///
/// Вынесено отдельным сценарием, потому что это единственное место, где секреты
/// покидают хранилище, — и его хочется видеть целиком.
public struct MaterializeProfile: Sendable {
    private let secrets: SecretStore

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    public func callAsFunction(_ profile: Profile) throws -> AwgConfig {
        var cfg = profile.config

        if cfg.interface.privateKey == Profile.secretPlaceholder {
            guard let key = try secrets.privateKey(profileID: profile.id) else {
                throw TunnelError.secretMissing(profileName: profile.name, what: "Private key")
            }
            cfg.interface.privateKey = key
        }

        for i in cfg.peers.indices where cfg.peers[i].presharedKey == Profile.secretPlaceholder {
            // Отсутствие PSK — такая же явная ошибка, как отсутствие приватного ключа.
            // Молчаливый nil давал туннель без preshared key, висящий без хендшейка.
            guard let psk = try secrets.presharedKey(profileID: profile.id, peerIndex: i) else {
                throw TunnelError.secretMissing(profileName: profile.name,
                                                what: "Preshared key for peer \(i + 1)")
            }
            cfg.peers[i].presharedKey = psk
        }
        return cfg
    }
}
