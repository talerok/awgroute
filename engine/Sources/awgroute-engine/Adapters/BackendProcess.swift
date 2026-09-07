import Foundation
import Darwin
import AwgProtocol

/// Управляет жизненным циклом amnezia-box subprocess'а: spawn, остановка, status.
/// Сериализован через одну очередь — все мутации currentPID идут через `queue.sync`.
final class BackendProcess: BackendRunning {


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
    /// Реальный home из passwd. Склейка "/Users/\(ownerUser)" врёт для сетевых
    /// и переименованных учёток — тогда лог уезжал в несуществующий путь.
    private let ownerHome: String
    private let queue = DispatchQueue(label: "dev.awgroute.helper.backend")

    private(set) var currentPID: Int32?
    private var startedAt: Date?

    init(binary: String, pidFile: String, ownerUID: UInt32, ownerUser: String) {
        self.binary = binary
        self.pidFile = pidFile
        self.ownerUID = ownerUID
        self.ownerUser = ownerUser
        self.ownerHome = Self.homeDirectory(forUID: ownerUID) ?? "/Users/\(ownerUser)"
    }

    /// Домашняя директория пользователя из passwd.
    static func homeDirectory(forUID uid: UInt32) -> String? {
        guard let pw = getpwuid(uid_t(uid)), let dir = pw.pointee.pw_dir else { return nil }
        let path = String(cString: dir)
        return path.isEmpty ? nil : path
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

    /// Жив ли backend прямо сейчас (с учётом зомби — см. processIsAlive).
    func isAlive() -> Bool {
        queue.sync {
            guard let pid = currentPID else { return false }
            return processIsAlive(pid) && processNameMatches(pid)
        }
    }

    func start(configPath: String) throws -> Int32 {
        return try queue.sync {
            if let pid = currentPID, processIsAlive(pid) {
                // Имя проверяем и здесь, не только в adoptExisting: после respawn'а
                // helper'а ребёнок мог быть пожат launchd'ом, pid освободиться и
                // достаться постороннему процессу. Иначе следующий stop() послал бы
                // SIGTERM/SIGKILL чужому процессу от root.
                if processNameMatches(pid) {
                    throw Failure.alreadyRunning(pid: pid)
                }
                Logger.shared.warn("pid \(pid) is no longer amnezia-box — dropping stale reference")
                currentPID = nil
                startedAt = nil
            }
            guard FileManager.default.isExecutableFile(atPath: binary) else {
                throw Failure.binaryNotFound(binary)
            }
            guard FileManager.default.fileExists(atPath: configPath) else {
                throw Failure.configNotFound(configPath)
            }

            // amnezia-box пишет логи в ~/Library/Logs/AwgRoute/amnezia-box.log пользователя.
            // App tailit'ит этот файл, поэтому не меняем.
            let logPath = EngineProtocol.Paths.backendLog(home: ownerHome)
            let logFD = openLogFile(logPath)
            defer { if let logFD { close(logFD) } }

            let pid = try spawnDetached(
                exec: binary,
                args: [binary, "run", "-c", configPath],
                logFD: logFD
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
            var died = true
            defer {
                // Если процесс пережил даже SIGKILL (например, залип в uninterruptible
                // I/O на utun), забывать его нельзя: следующий start() поднял бы второй
                // amnezia-box, они подрались бы за интерфейс, а остановить первый через
                // helper было бы уже нечем.
                if died {
                    currentPID = nil
                    startedAt = nil
                    try? FileManager.default.removeItem(atPath: pidFile)
                } else {
                    Logger.shared.error("backend pid=\(pid) survived SIGKILL — keeping reference")
                }
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
                died = !processIsAlive(pid)
            }
            // Отдельный waitpid не нужен: processIsAlive выше жнёт ребёнка сам.
        }
    }


    // MARK: - Private

    private func readPidFile() -> Int32? {
        guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Жив ли процесс — с учётом зомби.
    ///
    /// `kill(pid, 0)` для незапожатого ребёнка возвращает 0: запись в таблице процессов
    /// ещё есть. Раньше из-за этого упавший amnezia-box вечно числился работающим —
    /// status() отдавал running, DNS-override не снимался, а stop() каждый раз ждал
    /// 5 секунд и писал в лог «did not exit on TERM», хотя процесс давно мёртв.
    ///
    /// Поэтому сначала пробуем пожать: если это наш ребёнок и он завершился,
    /// `waitpid(WNOHANG)` вернёт его pid и запись исчезнет.
    private func processIsAlive(_ pid: Int32) -> Bool {
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        if reaped == pid {
            Logger.shared.info("reaped backend pid=\(pid) (exit status \(status))")
            return false
        }
        // reaped == -1 с ECHILD — процесс не наш ребёнок (после respawn helper'а
        // и adoptExisting), тогда полагаемся на kill(0).
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

    /// Открывает лог-файл backend'а и возвращает fd, готовый стать его stdout.
    ///
    /// Путь целиком контролируется пользователем, а мы root — поэтому ни `chown` по
    /// пути, ни `addopen` по пути использовать нельзя: и то и другое идёт по симлинку.
    /// Подменив лог симлинком на /etc/sudoers, пользователь заставил бы helper либо
    /// отдать себе владение чужим root-файлом, либо дописывать в него stdout backend'а.
    ///
    /// Поэтому: открываем с `O_NOFOLLOW` (на последнем компоненте) и правим владельца
    /// уже через `fchown` по полученному fd. Директорию создаём тоже без следования
    /// по ссылкам. Возвращаем nil, если открыть безопасно не вышло — вызывающий
    /// перенаправит вывод в /dev/null, это лучше, чем писать не туда.
    private func openLogFile(_ path: String) -> Int32? {
        let dir = (path as NSString).deletingLastPathComponent
        var dirStat = stat()
        if lstat(dir, &dirStat) != 0 {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Директорию только что создали сами — здесь chown по пути безопасен.
            chown(dir, ownerUID, 20)
        } else if (dirStat.st_mode & S_IFMT) == S_IFLNK || (dirStat.st_mode & S_IFMT) != S_IFDIR {
            Logger.shared.warn("log dir is a symlink or not a directory, refusing to use it: \(dir)")
            return nil
        }

        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0 {
            // ELOOP — путь оказался симлинком: ровно тот случай, от которого защищаемся.
            Logger.shared.warn("cannot open log \(path) safely (errno=\(errno)); backend output goes to /dev/null")
            return nil
        }
        // Проверяем уже ОТКРЫТЫЙ объект, а не путь: между open и проверкой подменить нечего.
        var st = stat()
        if fstat(fd, &st) != 0 || (st.st_mode & S_IFMT) != S_IFREG {
            Logger.shared.warn("log path is not a regular file, refusing: \(path)")
            close(fd)
            return nil
        }
        // Владельца отдаём пользователю, чтобы app читал лог без sudo. По fd, не по пути.
        fchown(fd, ownerUID, 20)
        fchmod(fd, 0o600)
        return fd
    }

    /// posix_spawn с SETSID, переадресацией I/O в /dev/null/log-файл.
    private func spawnDetached(exec: String, args: [String], logFD: Int32?) throws -> Int32 {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // POSIX_SPAWN_SETSID = 0x0400 на macOS (sys/spawn.h).
        // SETSID отвязывает child от controlling terminal'а helper'а — без этого backend
        // получит SIGHUP когда helper будет перезапускаться launchd'ом.
        //
        // POSIX_SPAWN_CLOEXEC_DEFAULT = 0x4000 — закрыть у ребёнка ВСЕ дескрипторы,
        // кроме явно перечисленных в file_actions. Без него amnezia-box наследовал
        // клиентский сокет текущего запроса (spawn происходит прямо во время его
        // обработки) и listening-сокет от launchd. Из-за унаследованного сокета
        // клиент не получал EOF после ответа и висел до SO_RCVTIMEO — тот самый
        // «timeout при уже поднятом туннеле», под который написан костыль с
        // параллельным поллингом .status на стороне приложения.
        let setsidFlag: Int16 = 0x0400
        let cloexecDefault: Int16 = 0x4000
        posix_spawnattr_setflags(&attr, setsidFlag | cloexecDefault)

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // stdin → /dev/null
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        // stdout → заранее открытый нами fd (см. openLogFile). Именно fd, а не путь:
        // addopen по пути пошёл бы по симлинку уже в контексте ребёнка.
        if let logFD {
            posix_spawn_file_actions_adddup2(&fileActions, logFD, 1)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        }
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
