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

    /// Текущий действующий конфиг amnezia-box.
    static let activeConfig: URL = appSupport.appendingPathComponent("active-config.json")

    /// Файл с PID работающего amnezia-box. Лежит в /tmp, потому что управляется root-процессом.
    static let pidFile = URL(fileURLWithPath: "/tmp/awgroute-amnezia-box.pid")

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
        // Кандидат 3: подняться от текущего exe до корня репо и взять backend/amnezia-box
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<10 {
            let cand = dir.appendingPathComponent("backend/amnezia-box")
            if FileManager.default.isExecutableFile(atPath: cand.path) { return cand }
            if dir.path == "/" { break }
            dir = dir.deletingLastPathComponent()
        }
        // Кандидат 4: жёстко зашитый путь — последний шанс
        let hardcoded = URL(fileURLWithPath: "/Users/artem/Documents/git/vpn-client/backend/amnezia-box")
        if FileManager.default.isExecutableFile(atPath: hardcoded.path) { return hardcoded }
        return nil
    }
}
