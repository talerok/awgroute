import Foundation

/// Переподнять туннель после пробуждения или восстановления сети.
///
/// Политика ретраев вынесена из `NetworkWatcher`, который лежал в инфраструктуре и
/// держал ссылки на UI-store'ы — стрелка зависимости смотрела наружу, и проверить
/// «три попытки с backoff, но только если туннель действительно жив» было нельзя никак.
public struct ReconnectTunnel: Sendable {
    private let connect: ConnectTunnel
    private let network: NetworkMonitoring
    private let status: @Sendable () async -> TunnelStatus
    private let sleep: @Sendable (Duration) async -> Void

    public let attempts: Int
    public let networkTimeout: TimeInterval

    public init(
        connect: ConnectTunnel,
        network: NetworkMonitoring,
        status: @escaping @Sendable () async -> TunnelStatus,
        attempts: Int = 3,
        networkTimeout: TimeInterval = 30,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.connect = connect
        self.network = network
        self.status = status
        self.attempts = attempts
        self.networkTimeout = networkTimeout
        self.sleep = sleep
    }

    @discardableResult
    public func callAsFunction(profile: Profile?) async -> TunnelStatus {
        // Без пригодного пути WireGuard-хендшейк уходит в никуда.
        _ = await network.waitForPath(timeout: networkTimeout)

        var lastFailure: String?
        for attempt in 0..<attempts {
            if attempt > 0 {
                // Экспоненциальный backoff: 2s, 4s, …
                await sleep(.seconds(2 << (attempt - 1)))
            }
            do {
                // Именно restart: при восстановлении сети процесс ещё жив, и обычный
                // connect не сделал бы ничего, а цикл счёл бы это успехом.
                let result = try await connect(profile: profile, mode: .restart)
                if result.isRunning { return result }
                lastFailure = "backend did not come up"
            } catch {
                lastFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        // Исчерпали попытки. Возвращать статус, снятый ДО них, нельзя: он остался бы
        // `.running` с прошлого раза, и вызывающий счёл бы провал успехом.
        return .failed(lastFailure ?? "reconnect failed after \(attempts) attempts")
    }
}
