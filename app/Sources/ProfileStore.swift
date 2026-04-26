import Foundation
import AwgConfig

/// Управляет коллекцией профилей: загрузка, импорт, удаление, активный профиль.
@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var profiles: [Profile] = []
    @Published var activeID: UUID? {
        didSet {
            if oldValue != activeID {
                UserDefaults.standard.set(activeID?.uuidString, forKey: "AwgRoute.activeProfileID")
            }
        }
    }

    private let dir: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init() {
        self.dir = Paths.appSupport.appendingPathComponent("profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let s = UserDefaults.standard.string(forKey: "AwgRoute.activeProfileID"),
           let id = UUID(uuidString: s) {
            self.activeID = id
        }
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let parsed: [Profile] = urls.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Profile.self, from: data)
        }
        self.profiles = parsed.sorted { $0.createdAt < $1.createdAt }
        // Если активный профиль удалён извне — сбросить
        if let id = activeID, !profiles.contains(where: { $0.id == id }) {
            self.activeID = nil
        }
    }

    var activeProfile: Profile? {
        guard let id = activeID else { return nil }
        return profiles.first { $0.id == id }
    }

    // MARK: - Import / Update / Delete

    /// Импортировать `.conf` файл. Возвращает созданный профиль.
    @discardableResult
    func importConf(at url: URL, name: String? = nil) throws -> Profile {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try AwgConfigParser.parse(text)
        let id = UUID()

        // Положить секреты в Keychain
        try KeychainStore.set(parsed.interface.privateKey, account: ProfileSecretAccounts.privateKey(profileID: id))
        for (i, peer) in parsed.peers.enumerated() {
            if let psk = peer.presharedKey, !psk.isEmpty {
                try KeychainStore.set(psk, account: ProfileSecretAccounts.peerPSK(profileID: id, peerIndex: i))
            }
        }

        // Сделать копию AwgConfig без секретов — её и сохраним в JSON.
        // Sentinel-значение `KEYCHAIN_REF` означает «секрет лежит в Keychain».
        var stripped = parsed
        stripped.interface.privateKey = Self.keychainSentinel
        for i in stripped.peers.indices {
            if let psk = stripped.peers[i].presharedKey, !psk.isEmpty {
                stripped.peers[i].presharedKey = Self.keychainSentinel
            }
        }

        let profile = Profile(
            id: id,
            name: name ?? url.deletingPathExtension().lastPathComponent,
            notes: "",
            createdAt: Date(),
            config: stripped
        )
        try persist(profile)
        reload()
        return profile
    }

    func update(_ profile: Profile) throws {
        try persist(profile)
        reload()
    }

    func delete(_ profile: Profile) throws {
        let url = dir.appendingPathComponent("\(profile.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        KeychainStore.deleteAll(forProfile: profile.id)
        if activeID == profile.id { activeID = nil }
        reload()
    }

    /// Собрать рантайм-конфиг (с подставленными секретами) для активного профиля.
    func materializedConfig(for profile: Profile) throws -> AwgConfig {
        var cfg = profile.config
        if cfg.interface.privateKey == Self.keychainSentinel {
            cfg.interface.privateKey = (try KeychainStore.get(account: ProfileSecretAccounts.privateKey(profileID: profile.id))) ?? ""
        }
        for i in cfg.peers.indices {
            if cfg.peers[i].presharedKey == Self.keychainSentinel {
                cfg.peers[i].presharedKey = try KeychainStore.get(account: ProfileSecretAccounts.peerPSK(profileID: profile.id, peerIndex: i))
            }
        }
        return cfg
    }

    static let keychainSentinel = "<keychain-ref>"

    private func persist(_ profile: Profile) throws {
        let url = dir.appendingPathComponent("\(profile.id.uuidString).json")
        let data = try encoder.encode(profile)
        try data.write(to: url, options: .atomic)
    }
}
