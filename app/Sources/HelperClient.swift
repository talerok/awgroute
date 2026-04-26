import Foundation
import Darwin

/// Клиент Unix-сокета `/var/run/awgroute-helper.sock`.
/// Helper-демон создаёт сокет через socket activation в launchd-плисте, мы только
/// connect/write/read/close.
///
/// Helper не установлен → сокет отсутствует → `HelperClient.isInstalled == false` →
/// `BackendController` идёт по legacy AppleScript-флоу.
enum HelperClient {

    static let socketPath = "/var/run/awgroute-helper.sock"

    enum HelperError: Error, CustomStringConvertible {
        case socketCreateFailed(errno: Int32)
        case connectFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case readFailed(errno: Int32)
        case decodeFailed(String)
        case helperReturnedError(String)

        var description: String {
            switch self {
            case .socketCreateFailed(let e):     return "socket() failed errno=\(e)"
            case .connectFailed(let e):          return "connect() failed errno=\(e) (\(String(cString: strerror(e))))"
            case .writeFailed(let e):            return "write() failed errno=\(e)"
            case .readFailed(let e):             return "read() failed errno=\(e)"
            case .decodeFailed(let s):           return "decode failed: \(s)"
            case .helperReturnedError(let msg):  return "helper: \(msg)"
            }
        }
    }

    enum Command {
        case start(configPath: String)
        case stop
        case restart(configPath: String)
        case status

        fileprivate var json: Data {
            // Кодируем вручную через JSONSerialization — на фоне 4 фиксированных команд
            // это проще и надёжнее, чем Codable с associated values.
            var dict: [String: Any] = [:]
            switch self {
            case .start(let path):   dict["cmd"] = "start";   dict["configPath"] = path
            case .stop:              dict["cmd"] = "stop"
            case .restart(let path): dict["cmd"] = "restart"; dict["configPath"] = path
            case .status:            dict["cmd"] = "status"
            }
            return (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data()
        }
    }

    struct Response: Decodable {
        let ok: Bool
        let error: String?
        let pid: Int32?
        let running: Bool?
        let uptime: Int?
    }

    /// True если файл сокета helper'а существует.
    /// Быстрая проверка без блокирующего I/O — безопасна для вызова с main thread.
    /// Если сокет-файл есть, но демон не слушает (stale после ручного bootout),
    /// первый же `send()` вернёт `connectFailed(errno: ECONNREFUSED)` — ошибка
    /// всплывёт в UI и пользователь сможет переустановить через Settings.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// Отправить команду, дождаться ответа. Вся I/O блокирующая, но запускается на
    /// фоновом thread'е через `Task.detached`.
    ///
    /// Дефолтный timeout — 30 сек: cold-start helper'а через socket activation на
    /// macOS медленный (Swift runtime + posix_spawn ~2-3 сек). На warm соединениях
    /// ответ обычно за <100ms.
    static func send(_ command: Command, timeout: TimeInterval = 30) async throws -> Response {
        return try await Task.detached(priority: .userInitiated) {
            try sendBlocking(command, timeout: timeout)
        }.value
    }

    // MARK: - Private

    private static func sendBlocking(_ command: Command, timeout: TimeInterval) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw HelperError.socketCreateFailed(errno: errno) }
        defer { close(fd) }

        // Таймауты на чтение/запись через socket-level options.
        var tv = timeval(tv_sec: __darwin_time_t(timeout), tv_usec: 0)
        let tvSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)

        // Подготовить sockaddr_un. sun_path — fixed-size массив из 104 CChar на macOS.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathLimit = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= pathLimit else {
            throw HelperError.connectFailed(errno: ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: pathLimit + 1) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[pathBytes.count] = 0
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult < 0 { throw HelperError.connectFailed(errno: errno) }

        // Записать запрос.
        let request = command.json
        var sent = 0
        try request.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress else { return }
            while sent < request.count {
                let n = write(fd, base.advanced(by: sent), request.count - sent)
                if n <= 0 { throw HelperError.writeFailed(errno: errno) }
                sent += n
            }
        }
        // Полу-закрыть запись, чтобы helper увидел EOF и точно отправил ответ. Стандартный
        // request/response paттерн на Unix-сокете.
        shutdown(fd, SHUT_WR)

        // Прочитать ответ. Команды короткие, но возьмём 64K чтобы не упереться.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                return read(fd, ptr.baseAddress, ptr.count)
            }
            if n == 0 { break }
            if n < 0 { throw HelperError.readFailed(errno: errno) }
            buffer.append(chunk, count: n)
            if buffer.count > 1024 * 1024 { break } // sanity-cap 1 MB
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: buffer)
        } catch {
            throw HelperError.decodeFailed("\(error): \(String(data: buffer, encoding: .utf8) ?? "<binary>")")
        }
        if !response.ok {
            throw HelperError.helperReturnedError(response.error ?? "unknown")
        }
        return response
    }
}
