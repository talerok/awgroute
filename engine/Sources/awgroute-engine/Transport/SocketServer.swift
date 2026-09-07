import Foundation
import Darwin
import AwgProtocol

// `launch_activate_socket` — из libxpc, отдаёт fd сокетов, выделенных launchd'ом
// по записи в plist. Готовой обёртки в Swift нет.
@_silgen_name("launch_activate_socket")
private func launch_activate_socket(
    _ name: UnsafePointer<CChar>,
    _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
    _ cnt: UnsafeMutablePointer<Int>
) -> Int32

// SOL_LOCAL/LOCAL_PEERCRED не экспонируются Swift Darwin'ом. Значения из <sys/un.h>.
private let kSOL_LOCAL: Int32 = 0
private let kLOCAL_PEERCRED: Int32 = 0x001
private let kLOCAL_PEERPID: Int32 = 0x002

/// Приём соединений, проверка UID клиента, обработка команд и рассылка событий.
///
/// В v2 соединение не обязано быть коротким: после `subscribe` оно живёт, и движок
/// пишет в него по строке JSON на каждое изменение состояния. Без этого движок не мог
/// бы сообщить о том, чего клиент не спрашивал, — а именно на этом строится
/// его самостоятельность.
final class SocketServer: StateBroadcasting, @unchecked Sendable {

    private let ownerUID: UInt32
    private var dispatcher: CommandDispatcher!

    /// Открытые подписки. Пишем в них из любого потока, поэтому под замком.
    private let subscribersLock = NSLock()
    private var subscribers: Set<Int32> = []

    private let workerQueue = DispatchQueue(
        label: "dev.awgroute.engine.worker", qos: .userInitiated, attributes: .concurrent)

    init(ownerUID: UInt32) {
        self.ownerUID = ownerUID
    }

    func attach(dispatcher: CommandDispatcher) {
        self.dispatcher = dispatcher
    }

    // MARK: - StateBroadcasting

    func broadcast(_ state: EngineProtocol.State) {
        guard var line = try? JSONEncoder().encode(EngineProtocol.Event(state: state)) else { return }
        line.append(0x0A)   // события разделяются \n

        subscribersLock.lock()
        let targets = subscribers
        subscribersLock.unlock()

        var dead: [Int32] = []
        for fd in targets where !writeAll(fd: fd, data: line) {
            dead.append(fd)
        }
        guard !dead.isEmpty else { return }
        subscribersLock.lock()
        for fd in dead {
            subscribers.remove(fd)
            close(fd)
        }
        subscribersLock.unlock()
        Logger.shared.info("dropped \(dead.count) dead subscriber(s)")
    }

    // MARK: - Accept loop

    /// Не возвращается: блокирует main thread на accept.
    func run() -> Never {
        let listenFD = obtainListenSocket()
        Logger.shared.info("listening on socket fd=\(listenFD)")

        // Без этого запись в закрытый клиентом сокет убила бы движок.
        signal(SIGPIPE, SIG_IGN)

        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                let err = errno
                if err == EINTR || err == ECONNABORTED { continue }
                Logger.shared.error("accept failed: \(String(cString: strerror(err)))")
                usleep(100_000)   // не крутить плотный цикл на EMFILE
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)

            logPeer(fd: client)
            guard verifyPeerUID(fd: client) else {
                Logger.shared.warn("peer UID mismatch — rejecting")
                close(client)
                continue
            }

            workerQueue.async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    // MARK: - Private

    private func obtainListenSocket() -> Int32 {
        var fds: UnsafeMutablePointer<Int32>?
        var count = 0
        let result = "Listener".withCString { launch_activate_socket($0, &fds, &count) }
        guard result == 0, count > 0, let array = fds else {
            Logger.shared.error("launch_activate_socket failed: result=\(result) count=\(count)")
            exit(2)
        }
        let fd = array[0]
        free(array)
        // Иначе backend унаследует listening-сокет и после смерти движка connect
        // к нему продолжит успешно завершаться в backlog, который никто не accept'ит.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    private func verifyPeerUID(fd: Int32) -> Bool {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let res = withUnsafeMutablePointer(to: &cred) {
            getsockopt(fd, kSOL_LOCAL, kLOCAL_PEERCRED, $0, &len)
        }
        guard res == 0 else {
            Logger.shared.error("getsockopt LOCAL_PEERCRED failed errno=\(errno)")
            return false
        }
        return cred.cr_uid == ownerUID
    }

    /// Аудит вызывающего.
    ///
    /// Полноценная проверка подписи невозможна: приложение подписано ad-hoc, его
    /// designated requirement — cdhash конкретной сборки, меняющийся при каждой
    /// пересборке и отличающийся у dev-сборки. Строгая проверка ломала бы рабочий
    /// процесс, проверка по пути обходится тривиально. Поэтому — не защита, а след
    /// в логе. Настоящей проверка станет со стабильной подписью Developer ID.
    private func logPeer(fd: Int32) {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, kSOL_LOCAL, kLOCAL_PEERPID, &pid, &len) == 0 else { return }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        Logger.shared.info("client pid=\(pid) path=\(n > 0 ? String(cString: buf) : "<unknown>")")
    }

    private func handle(client fd: Int32) {
        // Таймауты нужны только на фазе запроса: подписчик молчит по определению,
        // и обрывать его по таймауту нельзя.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)

        guard let request = readRequest(fd: fd), !request.isEmpty else {
            close(fd)   // probe-коннект без данных: GUI так проверяет наличие сокета
            return
        }

        let outcome = dispatcher.handle(request)
        guard writeAll(fd: fd, data: outcome.response) else {
            close(fd)
            return
        }

        guard outcome.subscribe else {
            close(fd)
            return
        }

        // Подписка: соединение остаётся жить, таймауты снимаем.
        var none = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &none, size)
        subscribersLock.lock()
        subscribers.insert(fd)
        subscribersLock.unlock()
        Logger.shared.info("subscriber attached (fd=\(fd))")
        // fd закроется в broadcast, когда запись перестанет проходить.
    }

    /// Читает один запрос. Клиент делает shutdown(SHUT_WR) после отправки,
    /// поэтому граница — EOF.
    private func readRequest(fd: Int32) -> Data? {
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let limit = 4 * 1024 * 1024   // конфиг теперь едет целиком, но не бесконечный
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                request.append(chunk, count: n)
                if request.count > limit {
                    Logger.shared.warn("request exceeds \(limit) bytes — dropping")
                    return nil
                }
                continue
            }
            if n == 0 { break }
            if errno == EINTR { continue }
            Logger.shared.warn("read failed: \(String(cString: strerror(errno)))")
            return request.isEmpty ? nil : request
        }
        return request
    }

    @discardableResult
    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            var sent = 0
            while sent < buf.count {
                let n = write(fd, base.advanced(by: sent), buf.count - sent)
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}
