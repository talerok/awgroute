import Foundation

// Порты — единственный способ, которым домен дотягивается наружу. Все зависимости
// направлены сюда, внутрь: инфраструктура знает о домене, домен об инфраструктуре — нет.
// Поэтому сценарии тестируются без macOS, без root и без реального backend'а.

// MARK: - Управление туннелем

/// Канал к тому, кто реально владеет процессом backend'а (у нас — helper-демон).
///
/// Здесь нет ни pid-файлов, ни `kill(pid, 0)`: приложение больше не пытается
/// самостоятельно судить о живости процесса. Единственный источник истины — `status()`.
public protocol TunnelGateway: Sendable {
    /// Доступен ли канал вообще (helper установлен и отвечает).
    var isAvailable: Bool { get }

    /// Конфиг передаётся СОДЕРЖИМЫМ, а не путём: файлом владеет тот, кто запускает
    /// backend. Иначе неизбежна гонка — одна сторона удаляет файл, который другая
    /// ещё не успела открыть.
    func start(config: Data, dnsServers: [String]) async throws -> TunnelStatus
    func stop() async throws
    /// Атомарный перезапуск. Нужен отдельной операцией: `stop` + `start` снимает и
    /// заново накатывает system DNS override, из-за чего резолвер «моргает».
    func restart(config: Data, dnsServers: [String]) async throws -> TunnelStatus
    func status() async throws -> TunnelStatus
    /// Поток состояний. Владелец процесса сообщает о переходах сам — включая те,
    /// о которых его не спрашивали.
    func events() -> AsyncStream<TunnelStatus>
}

/// Проверка сгенерированного конфига ДО запуска.
///
/// Схема backend'а меняется между версиями (`geoip` удалён в 1.12, `download_detour`
/// устарел в 1.14), и пользователь редактирует её напрямую. Без предварительной
/// проверки ошибка всплывала `FATAL`-ом в логе через десять секунд после Connect.
public protocol ConfigValidating: Sendable {
    /// Возвращает описание проблемы, либо nil если конфиг принят.
    /// Принимает содержимое: временный файл, если он нужен проверяльщику, —
    /// его собственная деталь.
    func validate(config: Data) async -> String?
}

// MARK: - Хранилища

public protocol ProfileRepository: Sendable {
    func load() throws -> [Profile]
    func save(_ profile: Profile) throws
    func delete(id: UUID) throws
}

/// Секреты профиля. Отдельно от `ProfileRepository`, потому что у них разные
/// требования к хранению: профиль — обычный файл, секрет — Keychain.
public protocol SecretStore: Sendable {
    func privateKey(profileID: UUID) throws -> String?
    func setPrivateKey(_ value: String, profileID: UUID) throws
    func presharedKey(profileID: UUID, peerIndex: Int) throws -> String?
    func setPresharedKey(_ value: String, profileID: UUID, peerIndex: Int) throws
    func deleteAll(profileID: UUID, peerCount: Int)
}

public protocol RulesRepository: Sendable {
    func load() -> RoutingRules
    func save(_ rules: RoutingRules) throws
}

// MARK: - Конфиг

/// Превращение профиля и правил в конфиг backend'а.
///
/// Домен не знает ни имён полей sing-box, ни того, что это вообще sing-box.
public protocol ConfigRendering: Sendable {
    func render(config: AwgConfig, rules: RoutingRules?, options: RenderOptions) throws -> Data
    /// Разбор правил для валидации в редакторе.
    func validate(rules: RoutingRules) -> RulesValidation
}

/// То, что вычисляет слой сценариев и передаёт рендереру.
public struct RenderOptions: Equatable, Sendable {
    public var remoteDNSServer: String
    public var cacheFilePath: String?
    public var clashAPISecret: String?

    public init(remoteDNSServer: String, cacheFilePath: String? = nil, clashAPISecret: String? = nil) {
        self.remoteDNSServer = remoteDNSServer
        self.cacheFilePath = cacheFilePath
        self.clashAPISecret = clashAPISecret
    }
}

// MARK: - Окружение

/// Пути файловой системы.
///
/// Порт, а не набор констант, потому что те же пути знает helper — и раньше они были
/// продублированы в двух модулях, которые собираются раздельно. Рассинхрон давал
/// молчаливый отказ.
public protocol RuntimePaths: Sendable {
    /// Кеш backend'а (скачанные rule-set'ы). Путь в home пользователя — движок
    /// пишет туда под root, но читаемость для GUI полезна при разборе проблем.
    var backendCache: String { get }
    var backendLog: String { get }
}

/// Генератор одноразовых секретов (Clash API). Порт — чтобы тесты были детерминированы.
public protocol SecretGenerating: Sendable {
    func newSecret() -> String
}

// MARK: - Порты, добавленные при разборе протечек слоёв

/// Разбор `.conf`-файла AmneziaWG.
public protocol ConfigParsing: Sendable {
    /// Возвращает конфиг и предупреждения парсера (неподдерживаемые параметры и т.п.).
    func parse(_ text: String) throws -> (config: AwgConfig, warnings: [String])
}

/// Источник строк лога backend'а для UI.
///
/// Следование за файлом и разовое чтение хвоста разделены намеренно: следить имеет
/// смысл только пока backend пишет, а показать историю прошлой сессии нужно и при
/// выключенном туннеле. Раньше это было одним бесконечным циклом, который опрашивал
/// файл каждые 200 мс вне зависимости от того, есть ли кому в него писать.
public protocol LogSource: Sendable {
    /// Поток новых строк. Завершается при отмене задачи-потребителя.
    func follow() -> AsyncStream<String>
    /// Разовый снимок хвоста — история без подписки.
    func recentTail() -> [String]
    /// Последняя строка FATAL из хвоста — причина падения вместо абстрактного «exited».
    func lastFatal() -> String?
}

/// Состояние сетевого пути.
public protocol NetworkMonitoring: Sendable {
    /// true при переходе в satisfied, false при потере пути.
    func pathUpdates() -> AsyncStream<Bool>
    /// Дождаться пригодного пути. Возвращает false по таймауту.
    func waitForPath(timeout: TimeInterval) async -> Bool
}

/// Засыпание и пробуждение машины.
public enum PowerEvent: Sendable { case willSleep, didWake }

public protocol PowerMonitoring: Sendable {
    func events() -> AsyncStream<PowerEvent>
}

/// Есть ли вообще бинарь backend'а.
public protocol BackendAvailability: Sendable {
    var isBackendPresent: Bool { get }
}

/// Что известно о самом движке — для диагностики в UI.
public struct EngineHealth: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        /// Сокет есть, но движок не отвечает — завис либо не поднялся.
        case unreachable(String)
        case running(pid: Int32, uptime: Int, version: Int)
        /// Версия протокола не совпала: нужен апгрейд.
        case incompatible(String)
    }
    public let state: State

    public init(state: State) { self.state = state }
}

/// Диагностика и перезапуск движка.
///
/// Отдельно от установки: «переустановить демон» и «перезапустить зависший» —
/// разные операции с разной ценой. Полное удаление остаётся за `EngineInstalling`.
public protocol EngineControlling: Sendable {
    func health() async -> EngineHealth
    /// Перезапуск через launchd. Требует прав администратора.
    func restart() async throws
}

/// Установка привилегированного движка.
public protocol EngineInstalling: Sendable {
    var isInstalled: Bool { get }
    func install() async throws
    func uninstall() async throws
    func installOnFirstLaunchIfNeeded() async
    /// Пользователь однажды отказался от установки — больше не предлагаем сами.
    /// Явное нажатие Enable этот отказ снимает.
    var userDeclined: Bool { get nonmutating set }
}

/// Телеметрия активного соединения.
public struct TrafficSample: Equatable, Sendable {
    public let up: UInt64
    public let down: UInt64
    public init(up: UInt64, down: UInt64) {
        self.up = up
        self.down = down
    }
}

public protocol TelemetrySource: Sendable {
    func traffic() -> AsyncStream<TrafficSample>
    func externalIP() async -> String?
}
