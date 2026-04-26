import Foundation

/// Пути, специфичные для AwgRoute.
enum Paths {

    /// `~/Library/Application Support/AwgRoute/`
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("AwgRoute", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// `~/Library/Logs/AwgRoute/`
    static let logsDir: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Logs/AwgRoute", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Полный путь к лог-файлу backend.
    static let backendLog: URL = logsDir.appendingPathComponent("amnezia-box.log")

    /// `~/Library/Caches/AwgRoute/` — для конфигов с секретами и runtime-state.
    /// Caches исключаются из Time Machine и iCloud backup.
    static let cachesDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("AwgRoute", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // 700: только владелец может листать содержимое.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }()

    /// Текущий действующий конфиг amnezia-box. В Caches (а не Application Support):
    /// файл содержит распакованный AWG private key — не должен попадать в Time Machine.
    static let activeConfig: URL = cachesDir.appendingPathComponent("active-config.json")

    /// Файл с PID работающего amnezia-box. В Caches под user-only директорией —
    /// в /tmp его мог бы переписать любой локальный процесс, и наш `kill -TERM` под
    /// sudo застрелил бы произвольный процесс root'а.
    static let pidFile: URL = cachesDir.appendingPathComponent("backend.pid")

    /// Путь к amnezia-box бинарнику. Ищем сначала рядом с .app (для Release-сборки),
    /// потом по пути репозитория относительно текущего исполняемого файла (для dev).
    static func backendBinary() -> URL? {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        // Кандидат 1: .app/Contents/Resources/amnezia-box
        if let bundleResources = Bundle.main.resourceURL {
            let cand = bundleResources.appendingPathComponent("amnezia-box")
            if FileManager.default.isExecutableFile(atPath: cand.path) { return cand }
        }
        // Кандидат 2: env override
        if let env = ProcessInfo.processInfo.environment["AWGROUTE_BACKEND"] {
            let cand = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: cand.path) { return cand }
        }
        // Кандидат 3: подняться от текущего exe до корня репо и взять backend/amnezia-box.
        // Глубина 10 уровней покрывает Xcode DerivedData (.../Build/Products/Debug/AwgRoute.app/Contents/MacOS/).
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<10 {
            let cand = dir.appendingPathComponent("backend/amnezia-box")
            if FileManager.default.isExecutableFile(atPath: cand.path) { return cand }
            if dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
