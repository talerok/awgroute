import Foundation
import AwgProtocol

// Порты движка. Швы, в которые упрётся будущее: хранение конфига, шаги активации,
// источник команды на переподключение. Сегодня у каждого одна реализация — важно,
// что вторая появится не переписыванием `TunnelSession`, а новым адаптером.

/// Где живёт конфиг backend'а, пока работает туннель.
///
/// Сегодня — `EphemeralConfigVault`: файл существует ровно столько, сколько работает
/// туннель, и стирается при остановке. Приватного ключа на диске между сессиями нет.
///
/// Когда движку понадобится поднимать туннель самостоятельно (после перезагрузки,
/// до входа пользователя), появится реализация поверх System keychain. Логика
/// `TunnelSession` при этом не меняется — меняется только то, что подставлено сюда.
protocol ConfigVault: AnyObject {
    /// Сохранить конфиг и вернуть путь, который получит backend.
    func store(_ config: Data) throws -> String
    func discard()
}

/// Запуск и остановка процесса backend'а.
protocol BackendRunning: AnyObject {
    var currentPID: Int32? { get }
    func isAlive() -> Bool
    func start(configPath: String) throws -> Int32
    func stop()
    /// Подхватить процесс, переживший перезапуск движка.
    func adoptExisting()
}

/// Управление системным DNS.
protocol SystemDNSControlling: AnyObject {
    func apply(servers: [String]) throws
    func restore()
    func cleanupOrphanIfBackendDead(_ backendIsAlive: Bool)
}

/// Куда движок сообщает о смене состояния. Реализуется транспортом.
protocol StateBroadcasting: AnyObject, Sendable {
    func broadcast(_ state: EngineProtocol.State)
}
