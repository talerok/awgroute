import Foundation
import AwgDomain

/// Реализация `ConfigValidating` через `amnezia-box check`.
///
/// Backend умеет проверять конфиг без прав и без запуска туннеля. Без этой проверки
/// ошибка схемы (устаревшее поле, опечатка в пользовательских правилах) всплывала
/// `FATAL`-ом в логе через десять секунд после Connect, а UI всё это время показывал
/// «Running».
///
/// Временный файл — деталь проверяльщика: конфиг ему приходит содержимым, потому что
/// постоянным файлом владеет движок, а не приложение.
public struct BackendConfigValidator: ConfigValidating {

    public init() {}

    public func validate(config: Data) async -> String? {
        guard let binary = BackendBinary.locate() else { return nil }   // нечем проверять

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("awgroute-check-\(UUID().uuidString).json")
        do {
            try config.write(to: scratch, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: scratch.path)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = ["check", "-c", scratch.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0
                                    ? nil : Self.firstFatal(in: output))
            }
        }
    }

    /// Из вывода нужна одна строка — та, что объясняет отказ.
    public static func firstFatal(in data: Data) -> String {
        let cleaned = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
        let line = (cleaned.split(separator: "\n").first { $0.contains("FATAL") }
                    ?? cleaned.split(separator: "\n").last)
            .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "configuration rejected"
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}
