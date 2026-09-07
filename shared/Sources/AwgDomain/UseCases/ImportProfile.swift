import Foundation

/// Импорт `.conf` в профиль.
///
/// Раньше эта логика жила в UI-слое: `ProfileStore` сам звал парсер, сам раскладывал
/// секреты и сам делал откат через `defer`. То есть Presentation знал про адаптер
/// конфигов, а самая аккуратная часть импорта — откат записей Keychain при сбое —
/// не была покрыта ничем.
public struct ImportProfile: Sendable {
    private let parser: ConfigParsing
    private let repository: ProfileRepository
    private let secrets: SecretStore
    private let now: @Sendable () -> Date
    private let newID: @Sendable () -> UUID

    public init(
        parser: ConfigParsing,
        repository: ProfileRepository,
        secrets: SecretStore,
        now: @escaping @Sendable () -> Date = { Date() },
        newID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.parser = parser
        self.repository = repository
        self.secrets = secrets
        self.now = now
        self.newID = newID
    }

    public struct Result: Sendable {
        public let profile: Profile
        /// Предупреждения парсера: неподдерживаемые параметры, подозрительные значения.
        /// Показываются пользователю — иначе часть его `.conf` теряется молча.
        public let warnings: [String]
    }

    public func callAsFunction(confText: String, name: String) throws -> Result {
        let (parsed, warnings) = try parser.parse(confText)
        let id = newID()

        // Любая ошибка до конца — откат, чтобы не остались «сироты» в Keychain.
        var success = false
        defer { if !success { secrets.deleteAll(profileID: id, peerCount: parsed.peers.count) } }

        try secrets.setPrivateKey(parsed.interface.privateKey, profileID: id)
        for (i, peer) in parsed.peers.enumerated() {
            if let psk = peer.presharedKey, !psk.isEmpty {
                try secrets.setPresharedKey(psk, profileID: id, peerIndex: i)
            }
        }

        var stripped = parsed
        stripped.interface.privateKey = Profile.secretPlaceholder
        for i in stripped.peers.indices where !(stripped.peers[i].presharedKey ?? "").isEmpty {
            stripped.peers[i].presharedKey = Profile.secretPlaceholder
        }

        let profile = Profile(id: id, name: name, createdAt: now(), config: stripped)
        try repository.save(profile)
        success = true
        return Result(profile: profile, warnings: warnings)
    }
}

/// Удаление профиля вместе с его секретами.
public struct DeleteProfile: Sendable {
    private let repository: ProfileRepository
    private let secrets: SecretStore

    public init(repository: ProfileRepository, secrets: SecretStore) {
        self.repository = repository
        self.secrets = secrets
    }

    public func callAsFunction(_ profile: Profile) throws {
        try repository.delete(id: profile.id)
        secrets.deleteAll(profileID: profile.id, peerCount: profile.config.peers.count)
    }
}
