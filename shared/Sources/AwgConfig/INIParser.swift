import Foundation
import AwgDomain

/// Минимальный INI-парсер под формат WireGuard `.conf`.
///
/// Особенности:
/// - Секции `[Interface]` и `[Peer]` (peer может повторяться).
/// - `key = value`, ключи case-insensitive (PrivateKey == privatekey).
/// - Значение может содержать `=` и `<...>` (важно для I1-I5 параметров AWG),
///   режется только по ПЕРВОМУ `=`.
/// - Комментарии: строка начинается с `#` или `;`. Inline-комментарии не поддерживаются —
///   `.conf` от Amnezia их не использует, а значения параметров AWG могут содержать `#`.
/// - Пустые строки игнорируются.
struct INIParser {
    struct Section {
        var name: String
        var entries: [(key: String, value: String)]   // порядок важен для дубликатов
    }

    static func parse(_ text: String) throws -> [Section] {
        var sections: [Section] = []
        var currentSection: Section? = nil

        // Нормализуем переводы строк ДО разбиения. В Swift "\r\n" — это ОДИН Character
        // (grapheme cluster), не равный ни "\n", ни "\r". Поэтому прежний предикат
        // `$0 == "\n" || $0 == "\r"` на CRLF-файле не находил ни одного разделителя:
        // весь файл считался одной строкой и парсер падал на missingSection("Interface").
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")   // старый Mac-стиль
        let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let s = currentSection { sections.append(s) }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                // Повторная секция с тем же именем (кроме [Peer], который по формату
                // повторяется законно) — доливаем записи в уже собранную, а не заводим
                // вторую. Иначе второй [Interface] молча затирал первый в AwgConfigParser.
                if name.lowercased() != "peer",
                   let idx = sections.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                    currentSection = sections.remove(at: idx)
                } else {
                    currentSection = Section(name: name, entries: [])
                }
                continue
            }

            guard let eqIdx = line.firstIndex(of: "=") else {
                throw AwgConfigError.malformedLine(line: line, lineNumber: idx + 1)
            }
            let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                throw AwgConfigError.malformedLine(line: line, lineNumber: idx + 1)
            }
            if currentSection == nil {
                // Ключи до первой секции — игнорируем (чтобы не падать на BOM/прочей мути)
                continue
            }
            currentSection?.entries.append((key: key, value: value))
        }
        if let s = currentSection { sections.append(s) }
        return sections
    }
}
