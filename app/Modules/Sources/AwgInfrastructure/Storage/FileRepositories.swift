import Foundation
import AwgDomain

/// Реализация `ProfileRepository`: профиль — JSON-файл в Application Support.
///
/// Секретов в файле нет: на их месте `Profile.secretPlaceholder`, настоящие значения
/// живут в `SecretStore`.
public struct FileProfileRepository: ProfileRepository {
    public let directory: URL

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func load() throws -> [Profile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        var profiles: [Profile] = []
        for url in urls where url.pathExtension == "json" {
            do {
                profiles.append(try decoder.decode(Profile.self, from: try Data(contentsOf: url)))
            } catch {
                // Не проглатываем молча: раньше повреждённый профиль просто исчезал
                // из списка вместе со ссылкой на свои секреты в Keychain, и пользователь
                // видел «профилей нет» без единого объяснения.
                NSLog("[AwgRoute] skipping unreadable profile \(url.lastPathComponent): \(error)")
            }
        }
        return profiles.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ profile: Profile) throws {
        let url = directory.appendingPathComponent("\(profile.id.uuidString).json")
        try encoder.encode(profile).write(to: url, options: .atomic)
        // Профиль не содержит секретов, но содержит endpoint'ы, адреса и параметры
        // обфускации — не повод показывать это другим пользователям машины.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete(id: UUID) throws {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        do { try FileManager.default.removeItem(at: url) }
        catch let e as CocoaError where e.code == .fileNoSuchFile { /* уже удалён извне */ }
    }
}

/// Реализация `RulesRepository`: правила — один JSON-файл на всё приложение.
public struct FileRulesRepository: RulesRepository {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() -> RoutingRules {
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else { return .empty }
        return RoutingRules(text: text)
    }

    public func save(_ rules: RoutingRules) throws {
        try Data(rules.text.utf8).write(to: file, options: .atomic)
    }
}
