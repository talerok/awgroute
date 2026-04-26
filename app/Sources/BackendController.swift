import Foundation
import AppKit
import Darwin   // proc_name (libproc)

@MainActor
final class BackendController: ObservableObject {

    enum Status: Equatable {
        case stopped
        case starting
        case running(pid: Int32)
        case stopping
        case error(String)

        var label: String {
            switch self {
            case .stopped:        return "Stopped"
            case .starting:       return "Starting…"
            case .running(let p): return "Running (pid \(p))"
            case .stopping:       return "Stopping…"
            case .error(let m):   return "Error: \(m)"
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var binaryFound: Bool
    /// Кольцевой массив последних строк лога — UI читает напрямую отсюда.
    @Published private(set) var lines: [String] = []
    private static let maxLines = 5_000

    private var logTailerTask: Task<Void, Never>?
    private var logRotationTask: Task<Void, Never>?
    private let logBuffer = LogBuffer(capacity: 2_000)
    private var logBufferUnsubscribe: (() -> Void)?

    init() {
        self.binaryFound = Paths.backendBinary() != nil
        // Постоянная подписка на logBuffer — кладём в @Published lines,
        // UI берёт напрямую (без .task с AsyncStream, который терялся при
        // переключении tab'ов и пересоздании view).
        self.logBufferUnsubscribe = logBuffer.subscribe { [weak self] line in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.lines.count >= Self.maxLines { self.lines.removeFirst(1_000) }
                self.lines.append(line)
            }
        }
        // На случай предыдущего запуска, который не закрылся корректно: подцепиться
        // к существующему PID. ВАЖНО: проверяем имя процесса — если PID был
        // переиспользован (после краха amnezia-box и долгой паузы), мы не должны
        // adopt'ить чужой процесс как свой backend (UI бы показал "Running" указывая
        // на левый pid, при Disconnect security-проверка в stop() остановит kill,
        // но всё равно запутывает состояние). Stale PID-файл удаляем.
        if let pid = readPID() {
            if processIsAlive(pid) && Self.processNameMatchesBackendStatic(pid) {
                status = .running(pid: pid)
                startLogTailerIfNeeded()
                startLogRotationTimer()
            } else {
                try? FileManager.default.removeItem(at: Paths.pidFile)
            }
        }
    }

    /// UI вызывает для очистки видимого буфера.
    func clearLines() { lines.removeAll(keepingCapacity: false) }

    /// Прокинуть ошибку из coordinator/UI слоя в общий статус.
    /// Используется когда подготовка конфига упала ДО backend.start (например,
    /// материализация профиля или генерация JSON). Иначе ошибка остаётся в NSLog,
    /// и пользователь не видит почему Connect ничего не сделал.
    func reportError(_ message: String) {
        status = .error(message)
    }

    // MARK: - Start

    func start(configPath: String) async {
        // Из .error разрешаем стартовать (UX: после ошибки кнопка должна работать).
        // Из .starting/.running/.stopping — нет, это уже в процессе.
        switch status {
        case .stopped, .error: break
        case .starting, .running, .stopping: return
        }
        guard let binary = Paths.backendBinary() else {
            status = .error("amnezia-box не найден. Соберите backend/build.sh.")
            return
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            status = .error("Config not found: \(configPath)")
            return
        }
        status = .starting

        // Перед запуском — переоткрыть лог: ротация если > 5 МБ.
        rotateLogIfNeeded()

        // Стартуем tailer заранее — чтобы было видно сообщения о падении.
        startLogTailerIfNeeded()

        // Однострочный sh-скрипт: фоновый запуск с переадресацией I/O.
        // `nohup` НЕ используем: внутри `do shell script` нет TTY, и nohup падает
        // c "Inappropriate ioctl for device". sh из AppleScript не шлёт SIGHUP
        // детям при завершении, так что nohup тут не нужен — достаточно `&`
        // с redirected stdin/stdout/stderr и записи PID.
        //
        // chown user + chmod 600 на лог: backend стартует как root, но владельца
        // и права отдаём пользователю — наш tailer читает без sudo, чужие user'ы
        // системы не получают доступ к содержимому (резолвенным доменам и т.п.).
        let user = quote(NSUserName())
        let bash = """
        rm -f \(quote(Paths.pidFile.path)) ; \
        touch \(quote(Paths.backendLog.path)) ; \
        chown \(user) \(quote(Paths.backendLog.path)) 2>/dev/null ; \
        chmod 600 \(quote(Paths.backendLog.path)) ; \
        \(quote(binary.path)) run -c \(quote(configPath)) \
          >> \(quote(Paths.backendLog.path)) 2>> \(quote(Paths.backendLog.path)) < /dev/null & \
        echo $! > \(quote(Paths.pidFile.path)) ; \
        chown \(user) \(quote(Paths.pidFile.path)) 2>/dev/null ; \
        chmod 644 \(quote(Paths.pidFile.path)) 2>/dev/null ; \
        sleep 0.3
        """
        let script = """
        do shell script "\(escapeForAppleScriptString(bash))" with administrator privileges
        """

        do {
            _ = try await runAppleScriptDetached(script)
        } catch {
            status = .error("AppleScript: \(error.localizedDescription)")
            return
        }

        // Прочитать PID, проверить что процесс жив
        guard let pid = readPID() else {
            status = .error("PID file not written (\(Paths.pidFile.path))")
            return
        }
        // Дать ему ещё немного времени на инициализацию TUN
        try? await Task.sleep(nanoseconds: 300_000_000)
        if !processIsAlive(pid) {
            status = .error("amnezia-box exited immediately (см. логи)")
            return
        }
        status = .running(pid: pid)
        startLogTailerIfNeeded()
        startLogRotationTimer()
        // amnezia-box прочитал конфиг при старте и держит свою рабочую копию
        // в памяти. Распакованный AWG private key больше не должен лежать на диске.
        // (Если процесс упадёт и его автоматически перезапустят — мы пройдём через
        // ConnectionCoordinator.connect, который сгенерит конфиг заново.)
        try? FileManager.default.removeItem(at: Paths.activeConfig)
    }

    // MARK: - Stop

    func stop() async {
        switch status {
        case .stopped, .stopping:
            return
        case .starting:
            // start() сам выставит .running или .error — игнорируем gracefully.
            return
        case .running, .error:
            // .error — попробовать всё равно остановить, если процесс жив (см. recovery flow).
            break
        }
        status = .stopping

        let pid: Int32? = readPID()
        guard let pid = pid else {
            // Нет PID — нечего убивать, но lingering tailer/timer надо остановить.
            stopLogTailer()
            stopLogRotationTimer()
            status = .stopped
            return
        }

        // Оптимизация: если процесс уже мёртв (например, recovery после .error
        // когда amnezia-box упал) — не дёргаем sudo prompt, просто чистимся.
        if !processIsAlive(pid) {
            try? FileManager.default.removeItem(at: Paths.pidFile)
            stopLogTailer()
            stopLogRotationTimer()
            status = .stopped
            return
        }

        // Защита от подмены PID-файла: убедиться, что PID реально принадлежит
        // процессу с именем amnezia-box. Без этой проверки злонамеренный процесс
        // может записать в наш PID-файл произвольный pid (например, sshd) и при
        // следующем Disconnect мы убьём его как root.
        guard processNameMatchesBackend(pid) else {
            status = .error("PID \(pid) does not belong to amnezia-box (refusing to kill).")
            try? FileManager.default.removeItem(at: Paths.pidFile)
            stopLogTailer()
            stopLogRotationTimer()
            return
        }

        // Используем shell builtins (kill, exit) и команды из /usr/bin (sleep, rm) —
        // на macOS 26 Tahoe `/bin/true` отсутствует, а `/bin/{kill,sleep,rm}` есть
        // не у всех — безопаснее полагаться на PATH и builtins.
        let bash = """
        kill -TERM \(pid) 2>/dev/null ; \
        for i in 1 2 3 4 5 ; do \
          if ! kill -0 \(pid) 2>/dev/null ; then break ; fi ; \
          sleep 1 ; \
        done ; \
        kill -KILL \(pid) 2>/dev/null ; \
        rm -f \(quote(Paths.pidFile.path)) ; \
        exit 0
        """
        let script = """
        do shell script "\(escapeForAppleScriptString(bash))" with administrator privileges
        """
        do {
            _ = try await runAppleScriptDetached(script)
        } catch {
            status = .error("Stop failed: \(error.localizedDescription)")
            return
        }
        stopLogTailer()
        stopLogRotationTimer()
        status = .stopped
    }

    private func stopLogTailer() {
        logTailerTask?.cancel()
        logTailerTask = nil
    }

    private func stopLogRotationTimer() {
        logRotationTask?.cancel()
        logRotationTask = nil
    }

    /// Период проверка размера лога во время работы туннеля. amnezia-box открывает
    /// файл через shell-redirect `>>` (O_APPEND) — после truncate следующая запись
    /// от backend пойдёт с offset 0, не нужно слать SIGHUP. Старые строки теряются —
    /// это компромисс ради простоты (без помощника-демона).
    private func startLogRotationTimer() {
        logRotationTask?.cancel()
        logRotationTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)   // 1 час
                await self?.truncateLogIfTooLarge()
            }
        }
    }

    private func truncateLogIfTooLarge(maxBytes: UInt64 = 10 * 1024 * 1024) {
        let url = Paths.backendLog
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > maxBytes
        else { return }
        if let h = try? FileHandle(forUpdating: url) {
            try? h.truncate(atOffset: 0)
            try? h.close()
        }
    }

    /// Синхронный stop — для applicationWillTerminate (нет async runtime).
    /// Обходимся без AppleScript prompt, если можем — sudo всё равно надо для kill,
    /// но cached auth должен сработать в большинстве случаев.
    nonisolated func stopBlocking() {
        let pidPath = Paths.pidFile.path
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        // Та же проверка что и в async stop(): не убивать чужой процесс под root.
        guard Self.processNameMatchesBackendStatic(pid) else { return }
        let bash = "kill -TERM \(pid) 2>/dev/null; sleep 1; kill -KILL \(pid) 2>/dev/null; rm -f '\(pidPath)'; exit 0"
        let escaped = bash.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        // Игнорируем ошибки — лучше попытаться, чем оставить процесс
    }

    // MARK: - Internal

    private func startLogTailerIfNeeded() {
        if logTailerTask != nil && !logTailerTask!.isCancelled { return }
        let url = Paths.backendLog
        let buffer = logBuffer
        logTailerTask = Task.detached(priority: .utility) {
            await LogTailer.tail(file: url) { line in
                Task { await buffer.append(line) }
            }
        }
    }

    private func rotateLogIfNeeded(maxBytes: UInt64 = 5 * 1024 * 1024) {
        let path = Paths.backendLog.path
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > maxBytes
        {
            let rotated = path + ".1"
            try? fm.removeItem(atPath: rotated)
            try? fm.moveItem(atPath: path, toPath: rotated)
        }
    }

    private func readPID() -> Int32? {
        guard let s = try? String(contentsOf: Paths.pidFile, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        // kill(pid, 0) — POSIX-способ проверить существование процесса
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func processNameMatchesBackend(_ pid: Int32) -> Bool {
        Self.processNameMatchesBackendStatic(pid)
    }

    /// Защита от подмены PID-файла. `proc_name(...)` возвращает comm-имя процесса
    /// (макс 16 байт без расширения, например "amnezia-box"). Если PID был переписан
    /// на чужой процесс — имя не совпадёт, и мы не отправим ему kill под sudo.
    /// Static-версия для использования из nonisolated stopBlocking().
    nonisolated fileprivate static func processNameMatchesBackendStatic(_ pid: Int32) -> Bool {
        // proc_name пишет до 2*MAXCOMLEN+1 = 33 байт по доке Darwin; берём с запасом.
        var nameBuf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        guard n > 0 else { return false }
        let name = String(cString: nameBuf)
        // amnezia-box на macOS comm обрезается до 15 символов: "amnezia-box" (11 chars) — влезает.
        // Префиксная проверка — на случай возможного suffix'а от менеджеров запуска.
        return name == "amnezia-box" || name.hasPrefix("amnezia-box")
    }
}

// MARK: - AppleScript helpers

private func runAppleScriptDetached(_ source: String) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "AwgRoute.AppleScript", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "init failed"])
        }
        let result = script.executeAndReturnError(&err)
        if let err = err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? err.description
            throw NSError(domain: "AwgRoute.AppleScript",
                          code: (err[NSAppleScript.errorNumber] as? Int) ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return result.stringValue ?? ""
    }.value
}

private func escapeForAppleScriptString(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

/// `'` — shell-quoting для путей с пробелами и спецсимволами.
private func quote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
