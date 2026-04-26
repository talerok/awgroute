import Foundation
import AppKit

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

    private var logTailerTask: Task<Void, Never>?
    private let logBuffer = LogBuffer(capacity: 2_000)

    init() {
        self.binaryFound = Paths.backendBinary() != nil
        // На случай предыдущего запуска, который не закрылся корректно: подцепиться
        // к существующему PID в /tmp/awgroute-amnezia-box.pid.
        if let pid = readPID(), processIsAlive(pid) {
            status = .running(pid: pid)
            startLogTailerIfNeeded()
        }
    }

    /// Live-стрим логов для UI. Подписчик получает сначала весь буфер,
    /// затем новые строки по мере появления.
    var logs: AsyncStream<String> {
        AsyncStream { cont in
            let cancel = logBuffer.subscribe { line in cont.yield(line) }
            cont.onTermination = { _ in cancel() }
        }
    }

    // MARK: - Start

    func start(configPath: String) async {
        guard case .stopped = status else { return }
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

        // Однострочный bash-скрипт: nohup, redirect, в фон, печать PID в pidfile.
        // Всё внутри `do shell script ... with administrator privileges`,
        // что показывает родной macOS prompt пароля (и кэширует авторизацию ~5 мин).
        let bash = """
        /bin/rm -f \(quote(Paths.pidFile.path)) ; \
        /usr/bin/nohup \(quote(binary.path)) run -c \(quote(configPath)) \
          >> \(quote(Paths.backendLog.path)) 2>&1 < /dev/null & \
        /bin/echo $! > \(quote(Paths.pidFile.path)) ; \
        /bin/sleep 0.3
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
    }

    // MARK: - Stop

    func stop() async {
        switch status {
        case .stopped, .stopping, .starting, .error:
            return
        case .running:
            break
        }
        status = .stopping

        let pid: Int32? = readPID()
        guard let pid = pid else {
            status = .stopped
            return
        }

        let bash = """
        /bin/kill -TERM \(pid) 2>/dev/null ; \
        for i in 1 2 3 4 5 ; do \
          if ! /bin/kill -0 \(pid) 2>/dev/null ; then break ; fi ; \
          /bin/sleep 1 ; \
        done ; \
        /bin/kill -KILL \(pid) 2>/dev/null ; \
        /bin/rm -f \(quote(Paths.pidFile.path)) ; \
        /bin/true
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
        status = .stopped
    }

    /// Синхронный stop — для applicationWillTerminate (нет async runtime).
    /// Обходимся без AppleScript prompt, если можем — sudo всё равно надо для kill,
    /// но cached auth должен сработать в большинстве случаев.
    nonisolated func stopBlocking() {
        let pidPath = Paths.pidFile.path
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let bash = "kill -TERM \(pid) 2>/dev/null; sleep 1; kill -KILL \(pid) 2>/dev/null; rm -f '\(pidPath)'; true"
        let escaped = bash.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        // Игнорируем ошибки — лучше попытаться, чем оставить процесс
    }

    // MARK: - Internal

    private func startLogTailerIfNeeded() {
        if logTailerTask != nil { return }
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
