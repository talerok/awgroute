import Foundation

/// Глобальные правила роутинга — JSON, который пользователь редактирует на вкладке "Rules".
///
/// **Scope:** один rules.json на всё приложение, общий для всех профилей.
/// Решение: правила меняются редко, профили часто; глобальный scope удобнее (см. PLAN.md этап 4).
///
/// **Формат:** Вариант A — только секция `route` верхнего уровня:
///   `{ "rules": [...], "rule_set": [...], "final": "..." }`.
/// `AwgJSONGenerator.fullConfigJSON` обернёт это в полный конфиг с inbounds/outbounds/dns.
@MainActor
final class RulesStore: ObservableObject {

    @Published var text: String

    let url: URL = Paths.appSupport.appendingPathComponent("rules.json")

    init() {
        if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
            self.text = s
        } else {
            self.text = Self.defaultEmptyTemplate
        }
    }

    /// Сохранить текущий текст на диск. Бросит, если JSON невалиден.
    func save() throws {
        _ = try parsed()   // валидация
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Прочитать заново с диска (отмена несохранённых изменений).
    func revert() {
        if let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
            self.text = s
        } else {
            self.text = Self.defaultEmptyTemplate
        }
    }

    /// Прогнать через `JSONSerialization` + `JSONEncoder` для красивой переформатировки.
    func format() {
        guard let dict = try? parsed() else { return }
        if let pretty = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: pretty, encoding: .utf8)
        {
            self.text = s
        }
    }

    /// Распарсить текущий текст. Используется и для валидации, и для генерации конфига.
    func parsed() throws -> [String: Any] {
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = obj as? [String: Any] else {
            throw NSError(domain: "RulesStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Top-level must be an object."])
        }
        return dict
    }

    enum ValidationStatus: Equatable {
        case ok
        case error(String)
    }
    var validation: ValidationStatus {
        do { _ = try parsed(); return .ok }
        catch { return .error(error.localizedDescription) }
    }

    // MARK: - Presets

    struct Preset: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let resourceName: String   // имя файла без .json
    }
    static let presets: [Preset] = [
        .init(name: "Empty",            resourceName: "empty"),
        .init(name: "RU routing",       resourceName: "ru-routing"),
        .init(name: "Ad blocking",      resourceName: "ad-blocking"),
        .init(name: "Full Clash-style", resourceName: "full-clash-style"),
    ]

    func load(preset: Preset) {
        if let s = Self.bundledPresetText(named: preset.resourceName) { self.text = s }
    }

    private static func bundledPresetText(named name: String) -> String? {
        // Bundle.main для запущенного .app — пресеты подгружены через project.yml
        // как resources folder, лежат либо в подпапке rule-presets, либо в корне Resources.
        if let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "rule-presets")
            ?? Bundle.main.url(forResource: name, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return nil
    }

    static let defaultEmptyTemplate: String =
        """
        {
          "rules": [
            { "action": "sniff" },
            { "protocol": "dns", "action": "hijack-dns" }
          ],
          "final": "vpn"
        }
        """
}
