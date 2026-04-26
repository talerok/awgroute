import Foundation

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

        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let s = currentSection { sections.append(s) }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentSection = Section(name: name, entries: [])
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
