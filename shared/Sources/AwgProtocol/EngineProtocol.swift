import Foundation

/// Контракт между GUI и движком (`awgroute-engine`).
///
/// Линкуется в оба модуля — одно определение вместо двух наборов констант в
/// раздельно собираемых бинарях.
///
/// ## Что изменилось в v2
///
/// **Конфиг передаётся содержимым, а не путём.** Владельцем файла становится движок:
/// он пишет его в свой root-only каталог, запускает backend и стирает при остановке.
/// Это убирает гонку (GUI успевал удалить конфиг раньше, чем backend его открывал)
/// и заодно всю валидацию пути — префикс, симлинки, TOCTOU, владельца: GUI больше
/// не называет путь, проверять нечего.
///
/// **Появился поток событий.** Движок сам сообщает о смене состояния, а не отвечает
/// на периодический опрос. Без этого движок не может действовать самостоятельно —
/// например, переподнять упавший backend и сказать об этом.
public enum EngineProtocol {

    /// Поднимать при каждом несовместимом изменении команд, ответов или событий.
    ///
    /// v3: в ответ на `status` добавлены сведения о самом движке (`Info`). Формально
    /// поле опционально, но молча жить с двумя разными формами ответа под одной
    /// версией — ровно та беда, ради которой версия и заведена: клиент не смог бы
    /// отличить «движок старый» от «движок сломан».
    public static let version = 3

    // MARK: - Имена и пути

    public enum Names {
        public static let daemonLabel = "dev.awgroute.engine"
        public static let binary = "awgroute-engine"
        public static let socket = "/var/run/awgroute-engine.sock"
        public static let installedBinary = "/Library/PrivilegedHelperTools/awgroute-engine"
        public static let launchDaemonPlist = "/Library/LaunchDaemons/dev.awgroute.engine.plist"

        /// Наследие v1 — сносится при установке, иначе в системе окажутся два демона.
        public enum Legacy {
            public static let daemonLabel = "dev.awgroute.helper"
            public static let socket = "/var/run/awgroute-helper.sock"
            public static let installedBinary = "/Library/PrivilegedHelperTools/awgroute-helper"
            public static let launchDaemonPlist = "/Library/LaunchDaemons/com.awgroute.helper.plist"
        }
    }

    /// Каталоги движка. Конфиг живёт здесь, а не в пользовательском Caches:
    /// каталог доступен только root, поэтому приватный ключ не виден процессам
    /// пользователя вообще.
    public enum Paths {
        public static let stateDir = "/var/db/awgroute-engine"
        public static let activeConfig = "/var/db/awgroute-engine/active-config.json"
        public static let dnsBackup = "/var/db/awgroute-engine/dns-backup.json"
        public static let log = "/var/log/awgroute-engine.log"
        public static let pidFile = "/var/run/awgroute-engine-backend.pid"

        /// Лог backend'а остаётся в home пользователя: его читает GUI без прав root.
        public static let backendLogSubpath = "Library/Logs/AwgRoute"
        public static let backendLogName = "amnezia-box.log"
        public static func backendLog(home: String) -> String {
            "\(home)/\(backendLogSubpath)/\(backendLogName)"
        }
    }

    // MARK: - Команды

    public enum Command: String, Codable, Sendable {
        case start
        case stop
        case restart
        case status
        /// Подписка на события. Соединение остаётся открытым, движок пишет в него
        /// по событию на строку, пока клиент не отключится.
        case subscribe
    }

    public struct Request: Codable, Sendable {
        public var protocolVersion: Int
        public var command: Command
        /// Содержимое конфига backend'а. Только для `start` и `restart`.
        public var config: String?
        /// Системные DNS-серверы для override. Пустой список — не трогать.
        public var dnsServers: [String]?

        public init(command: Command, config: String? = nil, dnsServers: [String]? = nil) {
            self.protocolVersion = EngineProtocol.version
            self.command = command
            self.config = config
            self.dnsServers = dnsServers
        }
    }

    // MARK: - Состояние и ответы

    /// Состояние туннеля глазами движка — единственного, кто им владеет.
    public enum State: Codable, Equatable, Sendable {
        case stopped
        case running(pid: Int32)
        case failed(reason: String)
    }

    /// Сведения о самом движке — для диагностики из UI.
    ///
    /// Раньше о движке нельзя было узнать ничего, кроме «сокет существует»:
    /// разбираться, жив ли он и давно ли, приходилось через `ps` в терминале.
    public struct Info: Codable, Equatable, Sendable {
        public var pid: Int32
        /// Секунд с момента запуска движка.
        public var uptime: Int
        public var version: Int

        public init(pid: Int32, uptime: Int, version: Int = EngineProtocol.version) {
            self.pid = pid
            self.uptime = uptime
            self.version = version
        }
    }

    public struct Response: Codable, Sendable {
        public var protocolVersion: Int
        public var ok: Bool
        public var state: State?
        public var error: String?
        /// Заполняется на `status`. Опционально: старые движки поля не пришлют.
        public var engine: Info?

        public init(ok: Bool, state: State? = nil, error: String? = nil, engine: Info? = nil) {
            self.protocolVersion = EngineProtocol.version
            self.ok = ok
            self.state = state
            self.error = error
            self.engine = engine
        }
    }

    /// Событие в подписке. Одна строка JSON на событие, разделитель — `\n`.
    public struct Event: Codable, Sendable {
        public var protocolVersion: Int
        public var state: State

        public init(state: State) {
            self.protocolVersion = EngineProtocol.version
            self.state = state
        }
    }

    public static func versionMismatch(clientVersion: Int) -> String {
        "engine speaks protocol v\(version), client sent v\(clientVersion) — reinstall the engine"
    }
}
