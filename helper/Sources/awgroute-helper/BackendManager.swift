import Foundation
import Darwin

/// Управляет жизненным циклом amnezia-box subprocess'а: spawn, остановка, status.
/// Сериализован через одну очередь — все мутации currentPID идут через `queue.sync`.
final class BackendManager {

    struct Status {
        let running: Bool
        let pid: Int32?
        let uptime: Int?
    }

    enum Failure: Error, CustomStringConvertible {
        case binaryNotFound(String)
        case configNotFound(String)
        case alreadyRunning(pid: Int32)
        case spawnFailed(errno: Int32)

        var description: String {
            switch self {
            case .binaryNotFound(let p): return "binary not found: \(p)"
            case .configNotFound(let p): return "config not found: \(p)"
            case .alreadyRunning(let p): return "already running pid=\(p)"
            case .spawnFailed(let e):    return "spawn failed errno=\(e) (\(String(cString: strerror(e))))"
            }
        }
    }

    private let binary: String
    private let pidFile: String
    private let ownerUID: UInt32
    private let ownerUser: String
    private let queue = DispatchQueue(label: "dev.awgroute.helper.backend")

    private var currentPID: Int32?
    private var startedAt: Date?

    init(binary: String, pidFile: String, ownerUID: UInt32, ownerUser: String) {
        self.binary = binary
        self.pidFile = pidFile
        self.ownerUID = ownerUID
        self.ownerUser = ownerUser
    }

    /// Подцепиться к работающему amnezia-box по PID-файлу (на случай respawn'а helper'а).
    func adoptExisting() {
        queue.sync {
            guard let pid = readPidFile() else { return }
            guard processIsAlive(pid), processNameMatches(pid) else {
                try? FileManager.default.removeItem(atPath: pidFile)
                Logger.shared.info("stale PID file ignored: \(pid)")
                return
            }
            currentPID = pid
            // Точное время старта неизвестно — best-effort.
            startedAt = Date()
            Logger.shared.info("adopted existing backend pid=\(pid)")
        }
    }

    func start(configPath: String) throws -> Int32 {
        return try queue.sync {
            if let pid = currentPID, processIsAlive(pid) {
                throw Failure.alreadyRunning(pid: pid)
            }
            guard FileManager.default.isExecutableFile(atPath: binary) else {
                throw Failure.binaryNotFound(binary)
            }
            guard FileManager.default.fileExists(atPath: configPath) else {
                throw Failure.configNotFound(configPath)
            }

            // amnezia-box пишет логи в ~/Library/Logs/AwgRoute/amnezia-box.log пользователя.
            // App tailit'ит этот файл, поэтому не меняем.
            let logPath = "/Users/\(ownerUser)/Library/Logs/AwgRoute/amnezia-box.log"
            ensureLogReady(logPath)

            let pid = try spawnDetached(
                exec: binary,
                args: [binary, "run", "-c", configPath],
                logPath: logPath
            )

            currentPID = pid
            startedAt = Date()
            try? "\(pid)".write(toFile: pidFile, atomically: true, encoding: .utf8)
            // PID-файл нам нужен для adoptExisting, его читает только root → 600 хватит.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFile)

            Logger.shared.info("backend started pid=\(pid) config=\(configPath)")
            return pid
        }
    }

    func stop() {
        queue.sync {
            guard let pid = currentPID else { return }
            defer {
                currentPID = nil
                startedAt = nil
                try? FileManager.default.removeItem(atPath: pidFile)
            }
            guard processIsAlive(pid) else { return }

            Logger.shared.info("stopping backend pid=\(pid)")
            kill(pid, SIGTERM)
            // Ждём до 5 сек.
            for _ in 0..<50 {
                if !processIsAlive(pid) { break }
                usleep(100_000)
            }
            if processIsAlive(pid) {
                Logger.shared.warn("backend did not exit on TERM — sending KILL")
                kill(pid, SIGKILL)
                for _ in 0..<10 {
                    if !processIsAlive(pid) { break }
                    usleep(100_000)
                }
            }
            // Reap zombie. Если backend был запущен через posix_spawn, мы его родитель.
            var stat: Int32 = 0
            _ = waitpid(pid, &stat, WNOHANG)
        }
    }

    func status() -> Status {
        return queue.sync {
            if let pid = currentPID, processIsAlive(pid) {
                let uptime = startedAt.map { Int(Date().timeIntervalSince($0)) }
                return Status(running: true, pid: pid, uptime: uptime)
            }
            return Status(running: false, pid: nil, uptime: nil)
        }
    }

    // MARK: - Private

    private func readPidFile() -> Int32? {
        guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0) проверяет только существование. EPERM значит процесс есть, но не наш.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Проверка что процесс с этим PID — действительно amnezia-box (защита от reuse PID).
    private func processNameMatches(_ pid: Int32) -> Bool {
        var pathBuf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        guard n > 0 else { return false }
        let path = String(cString: pathBuf)
        return (path as NSString).lastPathComponent == "amnezia-box"
    }

    /// Создаёт лог-файл если его нет, выставляет владельца на пользователя (а не root).
    private func ensureLogReady(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        // Директория может быть создана уже приложением. Если её нет — создаём с владельцем-юзером.
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            chown(dir, ownerUID, 20)
        }
        // Файл создаём пустой если его нет, чтобы chown сработал до открытия posix_spawn'ом.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(
                atPath: path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        chown(path, ownerUID, 20)
    }

    /// posix_spawn с SETSID, переадресацией I/O в /dev/null/log-файл.
    private func spawnDetached(exec: String, args: [String], logPath: String) throws -> Int32 {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID = 0x0400 на macOS (sys/spawn.h).
        // SETSID отвязывает child от controlling terminal'а helper'а — без этого backend
        // получит SIGHUP когда helper будет перезапускаться launchd'ом.
        let setsidFlag: Int16 = 0x0400
        posix_spawnattr_setflags(&attr, setsidFlag)

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // stdin → /dev/null
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        // stdout → log
        posix_spawn_file_actions_addopen(&fileActions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        // stderr → дублирует stdout
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        // strdup'аем строки и terminator nil — С-style argv.
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.compactMap { $0 }.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, exec, &fileActions, &attr, cArgs, environ)
        if result != 0 {
            throw Failure.spawnFailed(errno: result)
        }
        return pid
    }
}
