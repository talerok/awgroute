import Foundation
import AwgInfrastructure
import AwgPresentation
import AwgDomain

/// Связывает системные события с сценарием переподключения.
///
/// Раньше это был `NetworkWatcher` в слое инфраструктуры, который держал ссылки на
/// UI-store'ы — зависимость смотрела наружу, а политику ретраев нельзя было проверить.
/// Теперь политика в `ReconnectTunnel` (домен и тесты), события — за портами,
/// а здесь остаётся только проводка, и её место — корень композиции.
@MainActor
final class TunnelSupervisor {

    private let tunnel: TunnelStore
    private let profiles: ProfileStore
    private let reconnect: ReconnectTunnel
    private let network: NetworkMonitoring
    private let power: PowerMonitoring
    private let engine: EngineInstalling

    private var tasks: [Task<Void, Never>] = []
    private var wasConnectedBeforeSleep = false
    private var isReconnecting = false
    private var lastPathSatisfied = true

    init(
        tunnel: TunnelStore,
        profiles: ProfileStore,
        reconnect: ReconnectTunnel,
        network: NetworkMonitoring,
        power: PowerMonitoring,
        engine: EngineInstalling
    ) {
        self.tunnel = tunnel
        self.profiles = profiles
        self.reconnect = reconnect
        self.network = network
        self.power = power
        self.engine = engine
    }

    deinit { tasks.forEach { $0.cancel() } }

    /// Автоматика имеет смысл только с установленным движком: без него каждое
    /// переподключение — промпт пароля, что хуже, чем не делать ничего.
    func start() {
        guard tasks.isEmpty, engine.isInstalled else { return }

        tasks.append(Task { [weak self] in
            guard let stream = self?.power.events() else { return }
            for await event in stream { await self?.handle(event) }
        })

        tasks.append(Task { [weak self] in
            guard let stream = self?.network.pathUpdates() else { return }
            for await satisfied in stream { await self?.handlePath(satisfied: satisfied) }
        })
    }

    // MARK: - Private

    private func handle(_ event: PowerEvent) async {
        switch event {
        case .willSleep:
            guard tunnel.status.isRunning else {
                wasConnectedBeforeSleep = false
                return
            }
            wasConnectedBeforeSleep = true
            await tunnel.disconnect()
        case .didWake:
            guard wasConnectedBeforeSleep else { return }
            wasConnectedBeforeSleep = false
            await performReconnect()
        }
    }

    private func handlePath(satisfied: Bool) async {
        let recovered = satisfied && !lastPathSatisfied
        lastPathSatisfied = satisfied
        // Переподключаемся только если путь ВОССТАНОВИЛСЯ и туннель считается живым:
        // процесс на месте, но его сокет смотрит в исчезнувший интерфейс.
        guard recovered, !wasConnectedBeforeSleep, tunnel.status.isRunning else { return }
        await performReconnect()
    }

    private func performReconnect() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        let result = await reconnect(profile: profiles.activeProfile)
        tunnel.apply(result)
    }
}
