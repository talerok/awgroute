import Foundation
import Darwin

// `launch_activate_socket` — функция из libxpc. Возвращает FD'шки сокетов, выделенных launchd'ом
// по записи в plist. На Swift нет готовой обёртки — bridge'им через @_silgen_name.
@_silgen_name("launch_activate_socket")
private func launch_activate_socket(
    _ name: UnsafePointer<CChar>,
    _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
    _ cnt: UnsafeMutablePointer<Int>
) -> Int32

// SOL_LOCAL/LOCAL_PEERCRED не всегда экспонируются Swift Darwin'ом — определяем сами.
// Значения из <sys/un.h>.
private let kSOL_LOCAL: Int32 = 0
private let kLOCAL_PEERCRED: Int32 = 0x001

/// Принимает соединения на Unix-сокете, проверяет UID клиента, передаёт команду в dispatcher.
final class SocketServer {

    private let ownerUID: UInt32
    private let dispatcher: CommandDispatcher

    init(ownerUID: UInt32, dispatcher: CommandDispatcher) {
        self.ownerUID = ownerUID
        self.dispatcher = dispatcher
    }

    /// Concurrent queue для обработки клиентов. BackendManager сериализован через
    /// свою отдельную queue, так что одновременная обработка нескольких команд safe.
    /// Без этого probe-connect от UI (для isInstalled) или медленная команда блокирует
    /// последующие — клиенты ловят SO_RCVTIMEO на read и возвращают ошибку, хотя
    /// помощник в реальности работает.
    private let workerQueue = DispatchQueue(
        label: "dev.awgroute.helper.worker",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Не возвращается. Блокирует main thread на accept loop. Каждый клиент уходит в
    /// concurrent worker queue.
    func run() -> Never {
        let listenFD = obtainListenSocket()
        Logger.shared.info("listening on socket fd=\(listenFD)")

        // Игнорируем SIGPIPE, чтобы запись в закрытый клиентом сокет не убивала helper.
        signal(SIGPIPE, SIG_IGN)

        while true {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &addr, &len)
            if client < 0 {
                if errno == EINTR { continue }
                Logger.shared.error("accept failed: \(String(cString: strerror(errno)))")
                continue
            }

            // Таймауты, чтобы зависший клиент не блокировал worker.
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            let tvSize = socklen_t(MemoryLayout<timeval>.size)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, tvSize)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, tvSize)

            guard verifyPeerUID(fd: client) else {
                Logger.shared.warn("peer UID mismatch — rejecting")
                close(client)
                continue
            }

            // Обработка в worker'е, accept loop возвращается к accept немедленно.
            workerQueue.async { [weak self] in
                self?.handle(client: client)
                close(client)
            }
        }
    }

    private func obtainListenSocket() -> Int32 {
        var fds: UnsafeMutablePointer<Int32>?
        var count: Int = 0
        let result = "Listener".withCString { name -> Int32 in
            return launch_activate_socket(name, &fds, &count)
        }
        guard result == 0, count > 0, let fdsArr = fds else {
            Logger.shared.error("launch_activate_socket failed: result=\(result) count=\(count)")
            exit(2)
        }
        let fd = fdsArr[0]
        // Освободить malloc'нутый launchd'ом массив.
        free(fdsArr)
        return fd
    }

    private func verifyPeerUID(fd: Int32) -> Bool {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let res = withUnsafeMutablePointer(to: &cred) { credPtr in
            getsockopt(fd, kSOL_LOCAL, kLOCAL_PEERCRED, credPtr, &len)
        }
        if res != 0 {
            Logger.shared.error("getsockopt LOCAL_PEERCRED failed errno=\(errno)")
            return false
        }
        return cred.cr_uid == ownerUID
    }

    private func handle(client fd: Int32) {
        let t0 = Date()
        // Читаем до EOF — клиент делает shutdown(SHUT_WR) после отправки запроса,
        // что гарантирует получение EOF даже если TCP разобьёт данные на чанки.
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 { request.append(chunk, count: n) }
            else { break }
        }
        if request.isEmpty {
            // Probe-connect (UI делает для проверки isInstalled) — короткий disconnect
            // без данных.
            return
        }
        let tRead = Date()
        let response = dispatcher.handle(request)
        let tHandle = Date()

        // Пишем ответ. SIGPIPE игнорим, write вернёт EPIPE если клиент уже отвалился.
        var sent = 0
        response.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while sent < response.count {
                let chunk = response.count - sent
                let w = write(fd, base.advanced(by: sent), chunk)
                if w <= 0 { break }
                sent += w
            }
        }
        let tWrite = Date()

        // Тайминг: read/handle/write в миллисекундах. Полезно для диагностики «UI висит
        // на старт» — видно где помощник тратит время.
        let readMs = Int(tRead.timeIntervalSince(t0) * 1000)
        let handleMs = Int(tHandle.timeIntervalSince(tRead) * 1000)
        let writeMs = Int(tWrite.timeIntervalSince(tHandle) * 1000)
        Logger.shared.info("handle done: read=\(readMs)ms handle=\(handleMs)ms write=\(writeMs)ms sent=\(sent)/\(response.count)")
    }
}
