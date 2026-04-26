import Foundation

/// JSON-команда от UI-клиента.
private struct Command: Decodable {
    let cmd: String
    let configPath: String?
}

/// Ответ helper'а. Все поля опциональны кроме `ok`.
private struct Response: Encodable {
    var ok: Bool
    var error: String?
    var pid: Int32?
    var running: Bool?
    var uptime: Int?
}

/// Парсит входящую команду, валидирует, делегирует BackendManager'у, формирует JSON-ответ.
final class CommandDispatcher {

    private let backend: BackendManager
    private let ownerUser: String
    private let allowedConfigPrefix: String

    init(backend: BackendManager, ownerUser: String) {
        self.backend = backend
        self.ownerUser = ownerUser
        self.allowedConfigPrefix = "/Users/\(ownerUser)/Library/Caches/AwgRoute/"
    }

    func handle(_ data: Data) -> Data {
        let command: Command
        do {
            command = try JSONDecoder().decode(Command.self, from: data)
        } catch {
            return encode(Response(ok: false, error: "invalid JSON: \(error)"))
        }
        Logger.shared.info("command: \(command.cmd)")

        switch command.cmd {
        case "start":   return handleStart(configPath: command.configPath)
        case "stop":    return handleStop()
        case "restart": return handleRestart(configPath: command.configPath)
        case "status":  return handleStatus()
        default:        return encode(Response(ok: false, error: "unknown command: \(command.cmd)"))
        }
    }

    // MARK: - Handlers

    private func handleStart(configPath: String?) -> Data {
        guard let path = configPath else {
            return encode(Response(ok: false, error: "configPath required"))
        }
        guard let validated = validateConfigPath(path) else {
            return encode(Response(ok: false, error: "invalid configPath"))
        }
        do {
            let pid = try backend.start(configPath: validated)
            return encode(Response(ok: true, pid: pid))
        } catch BackendManager.Failure.alreadyRunning(let pid) {
            // Идемпотентность: если бэкенд уже работает, это не ошибка для UI —
            // бывает после client-side timeout (helper успел spawn, клиент не дочитал
            // ответ, повторил запрос). Возвращаем OK с текущим pid, UI ставит .running.
            return encode(Response(ok: true, pid: pid))
        } catch {
            return encode(Response(ok: false, error: "\(error)"))
        }
    }

    private func handleStop() -> Data {
        backend.stop()
        return encode(Response(ok: true))
    }

    private func handleRestart(configPath: String?) -> Data {
        guard let path = configPath else {
            return encode(Response(ok: false, error: "configPath required"))
        }
        guard let validated = validateConfigPath(path) else {
            return encode(Response(ok: false, error: "invalid configPath"))
        }
        backend.stop()
        do {
            let pid = try backend.start(configPath: validated)
            return encode(Response(ok: true, pid: pid))
        } catch {
            return encode(Response(ok: false, error: "\(error)"))
        }
    }

    private func handleStatus() -> Data {
        let s = backend.status()
        var resp = Response(ok: true)
        resp.running = s.running
        resp.pid = s.pid
        resp.uptime = s.uptime
        return encode(resp)
    }

    // MARK: - Validation

    /// Проверяет configPath. Защита от запуска чужих конфигов:
    /// - абсолютный путь, без `..`,
    /// - находится в /Users/<owner>/Library/Caches/AwgRoute/,
    /// - не симлинк (чтобы нельзя было подсунуть симлинк на /etc/passwd),
    /// - существует как regular file.
    /// Возвращает «канонизированный» путь через resolvingSymlinksInPath, если все проверки прошли.
    private func validateConfigPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        guard !path.contains("..") else { return nil }
        guard path.hasPrefix(allowedConfigPrefix) else { return nil }

        let url = URL(fileURLWithPath: path)
        // Проверка что это не симлинк.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType,
           type == FileAttributeType.typeSymbolicLink {
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue
        else { return nil }
        return url.path
    }

    // MARK: - Encoding

    private func encode(_ r: Response) -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(r)
        } catch {
            return Data(#"{"ok":false,"error":"encode failed"}"#.utf8)
        }
    }
}
