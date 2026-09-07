import Foundation
import AwgProtocol

/// Конфиг живёт ровно столько, сколько работает туннель.
///
/// Каталог `/var/db/awgroute-engine` — root-only (0700), поэтому распакованный
/// приватный ключ не виден процессам пользователя вообще. Раньше конфиг лежал в
/// `~/Library/Caches/AwgRoute` под учёткой пользователя, и его удалением занимался
/// GUI — что и породило гонку: GUI успевал стереть файл до того, как backend его
/// открывал.
///
/// Секрета at rest здесь нет: `discard()` вызывается при остановке, и между сессиями
/// на диске не остаётся ничего. Реализация, переживающая перезагрузку, появится
/// отдельным адаптером, если понадобится автономный запуск.
final class EphemeralConfigVault: ConfigVault {

    private let path: String

    init(path: String = EngineProtocol.Paths.activeConfig) {
        self.path = path
    }

    func store(_ config: Data) throws -> String {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chown(dir, 0, 0)

        // Пишем через O_NOFOLLOW: путь наш и root-only, но привычка дешевле разбора
        // последствий. Заодно 0600 выставляется сразу, а не вторым шагом.
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw VaultError.cannotCreate(errno: errno)
        }
        defer { close(fd) }

        let written = config.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var total = 0
            while total < buf.count {
                let n = write(fd, base.advanced(by: total), buf.count - total)
                if n <= 0 { break }
                total += n
            }
            return total
        }
        guard written == config.count else {
            throw VaultError.shortWrite(written: written, expected: config.count)
        }
        return path
    }

    func discard() {
        try? FileManager.default.removeItem(atPath: path)
    }

    enum VaultError: Error, CustomStringConvertible {
        case cannotCreate(errno: Int32)
        case shortWrite(written: Int, expected: Int)

        var description: String {
            switch self {
            case .cannotCreate(let e):
                return "cannot create config file: \(String(cString: strerror(e)))"
            case .shortWrite(let w, let e):
                return "short write of config: \(w)/\(e) bytes"
            }
        }
    }
}
