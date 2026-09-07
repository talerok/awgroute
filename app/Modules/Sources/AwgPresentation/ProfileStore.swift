import Foundation
import AwgDomain

/// Коллекция профилей для UI.
///
/// Тонкая обёртка над `ProfileRepository` и `SecretStore`: вся работа с диском и
/// Keychain — в адаптерах, здесь только наблюдаемое состояние и активный профиль.
@MainActor
public final class ProfileStore: ObservableObject {

    @Published public private(set) var profiles: [Profile] = []
    /// Предупреждения парсера от последнего импорта: неподдерживаемые параметры и т.п.
    /// Runtime-only, в профиль не пишутся — иначе пользователь не узнает, что часть
    /// его `.conf` молча выброшена.
    @Published public private(set) var lastImportWarnings: [String] = []
    @Published public var activeID: UUID? {
        didSet {
            guard oldValue != activeID else { return }
            UserDefaults.standard.set(activeID?.uuidString, forKey: Self.activeKey)
        }
    }

    private static let activeKey = "AwgRoute.activeProfileID"
    private let repository: ProfileRepository
    private let importProfile: ImportProfile
    private let deleteProfile: DeleteProfile

    public init(repository: ProfileRepository, importProfile: ImportProfile, deleteProfile: DeleteProfile) {
        self.repository = repository
        self.importProfile = importProfile
        self.deleteProfile = deleteProfile
        if let s = UserDefaults.standard.string(forKey: Self.activeKey) { activeID = UUID(uuidString: s) }
        reload()
    }

    public var activeProfile: Profile? {
        guard let activeID else { return nil }
        return profiles.first { $0.id == activeID }
    }

    public func reload() {
        profiles = (try? repository.load()) ?? []
        if let id = activeID, !profiles.contains(where: { $0.id == id }) { activeID = nil }
    }

    /// Импорт `.conf`. Разбор, раскладка секретов и откат при сбое — в сценарии
    /// `ImportProfile`; здесь только чтение файла и обновление наблюдаемого состояния.
    @discardableResult
    public func importConf(at url: URL, name: String? = nil) throws -> Profile {
        let text = try String(contentsOf: url, encoding: .utf8)
        let result = try importProfile(
            confText: text,
            name: name ?? url.deletingPathExtension().lastPathComponent
        )
        lastImportWarnings = result.warnings
        reload()
        return result.profile
    }

    public func delete(_ profile: Profile) throws {
        try deleteProfile(profile)
        if activeID == profile.id { activeID = nil }
        reload()
    }
}
