import Foundation
import Darwin
import AwgProtocol

/// Клиент Unix-сокета движка.
///
/// Две роли: короткий запрос-ответ для команд и долгоживущее соединение под поток
/// событий. Раньше протокол был только запрос-ответ, и GUI опрашивал состояние раз
/// в пять секунд; теперь движок сообщает сам.
public enum EngineClient {

    public static let socketPath = EngineProtocol.Names.socket

    public enum Failure: Error, CustomStringConvertible {
        case socketCreateFailed(errno: Int32)
        case connectFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case readFailed(errno: Int32)
        case decodeFailed(String)
        case engineReturnedError(String)

        public var description: String {
            switch self {
            case .socketCreateFailed(let e): return "socket() failed errno=\(e)"
            case .connectFailed(let e):      return "connect() failed errno=\(e) (\(String(cString: strerror(e))))"
            case .writeFailed(let e):        return "write() failed errno=\(e)"
            case .readFailed(let e):         return "read() failed errno=\(e)"
            case .decodeFailed(let s):       return "decode failed: \(s)"
            case .engineReturnedError(let m): return m
            }
        }
    }

    /// Есть ли сокет движка. Быстрая проверка без блокирующего I/O.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    // MARK: - Запрос-ответ

    public static func send(_ request: EngineProtocol.Request,
                            timeout: TimeInterval = 30) async throws -> EngineProtocol.Response {
        try await Task.detached(priority: .userInitiated) {
            let fd = try connect(timeout: timeout)
            defer { close(fd) }
            let response = try exchange(fd: fd, request: request)
            guard response.ok else {
                throw Failure.engineReturnedError(response.error ?? "unknown engine error")
            }
            return response
        }.value
    }

    /// Синхронный вариант — для `applicationWillTerminate`, где async-рантайма уже нет.
    public static func sendSync(_ request: EngineProtocol.Request,
                                timeout: TimeInterval = 5) throws -> EngineProtocol.Response {
        let fd = try connect(timeout: timeout)
        defer { close(fd) }
        return try exchange(fd: fd, request: request)
    }

    // MARK: - Поток событий

    /// Подписка на состояния. Соединение живёт, пока жив потребитель потока.
    /// Обрыв (движок перезапустился) завершает поток — вызывающий решает, повторять ли.
    public static func events() -> AsyncStream<EngineProtocol.State> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    // Таймаута на чтение нет: подписчик молчит по определению.
                    let fd = try connect(timeout: 10, readTimeout: 0)
                    defer { close(fd) }
                    let first = try exchange(fd: fd, request: .init(command: .subscribe),
                                             halfClose: false)
                    if let state = first.state { continuation.yield(state) }

                    var buffer = Data()
                    var chunk = [UInt8](repeating: 0, count: 8 * 1024)
                    while !Task.isCancelled {
                        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                        if n <= 0 {
                            if n < 0 && errno == EINTR { continue }
                            break   // движок закрыл соединение
                        }
                        buffer.append(chunk, count: n)
                        // События разделены \n — по строке на событие.
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let line = buffer.prefix(upTo: nl)
                            buffer.removeSubrange(...nl)
                            if let event = try? JSONDecoder().decode(EngineProtocol.Event.self, from: line) {
                                continuation.yield(event.state)
                            }
                        }
                    }
                } catch {
                    NSLog("[AwgRoute] engine event stream ended: \(error)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private static func connect(timeout: TimeInterval, readTimeout: TimeInterval? = nil) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socketCreateFailed(errno: errno) }

        var send = timeval(tv_sec: __darwin_time_t(timeout), tv_usec: 0)
        var recv = timeval(tv_sec: __darwin_time_t(readTimeout ?? timeout), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recv, size)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let limit = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard bytes.count <= limit else {
            close(fd)
            throw Failure.connectFailed(errno: ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: limit + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result >= 0 else {
            let e = errno
            close(fd)
            throw Failure.connectFailed(errno: e)
        }
        return fd
    }

    /// Отправляет запрос и читает один ответ.
    ///
    /// `halfClose` закрывает запись, чтобы движок увидел границу запроса. Для подписки
    /// этого делать нельзя: соединение должно остаться двусторонним.
    private static func exchange(fd: Int32, request: EngineProtocol.Request,
                                 halfClose: Bool = true) throws -> EngineProtocol.Response {
        let payload = try JSONEncoder().encode(request)
        try payload.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var sent = 0
            while sent < buf.count {
                let n = write(fd, base.advanced(by: sent), buf.count - sent)
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw Failure.writeFailed(errno: errno)
            }
        }
        if halfClose { shutdown(fd, SHUT_WR) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var readErrno: Int32 = 0
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                readErrno = errno
                break
            }
            buffer.append(chunk, count: n)
            // Как только ответ распарсился — дочитывать до EOF незачем. Иначе на
            // соединении без half-close (подписка) упрёмся в таймаут.
            if (try? JSONDecoder().decode(EngineProtocol.Response.self, from: buffer)) != nil { break }
        }
        do {
            return try JSONDecoder().decode(EngineProtocol.Response.self, from: buffer)
        } catch {
            if readErrno != 0 { throw Failure.readFailed(errno: readErrno) }
            throw Failure.decodeFailed("\(error): \(String(decoding: buffer, as: UTF8.self))")
        }
    }
}
