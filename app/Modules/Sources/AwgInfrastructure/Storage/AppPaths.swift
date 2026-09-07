import Foundation
import AwgDomain
import AwgProtocol

/// Реализация `RuntimePaths`.
///
/// Единственное место в приложении, где вообще известны конкретные пути.
/// Раньше их знали пять файлов приложения и, независимо, пять файлов helper'а —
/// два набора констант в модулях, которые собираются раздельно.
public struct AppPaths: RuntimePaths {

    public static let shared = AppPaths()

    /// `~/Library/Application Support/AwgRoute/`
    public let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("AwgRoute", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// `~/Library/Logs/AwgRoute/`
    public let logsDir: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Logs/AwgRoute", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// `~/Library/Caches/AwgRoute/` — конфиги с секретами и runtime-state.
    /// Caches исключены из Time Machine и iCloud backup.
    public let cachesDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("AwgRoute", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }()

    public var profilesDir: URL { appSupport.appendingPathComponent("profiles", isDirectory: true) }
    public var rulesFile: URL { appSupport.appendingPathComponent("rules.json") }
    public var backendLogURL: URL { logsDir.appendingPathComponent(EngineProtocol.Paths.backendLogName) }

    // MARK: RuntimePaths

    /// Кеш backend'а: скачанные remote rule-set'ы. Переживает disconnect намеренно —
    /// смысл кеша в том, чтобы следующий старт не зависел от сети.
    public var backendCache: String { cachesDir.appendingPathComponent("backend-cache.db").path }
    public var backendLog: String { backendLogURL.path }
}

/// Поиск бинаря backend'а. Отдельно от путей: это про сборку, а не про runtime-состояние.
public enum BackendBinary {
    static func locate() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("amnezia-box")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        if let env = ProcessInfo.processInfo.environment["AWGROUTE_BACKEND"] {
            let candidate = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        // Dev-сборка: поднимаемся от исполняемого файла до корня репозитория.
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("backend/amnezia-box")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            if dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
