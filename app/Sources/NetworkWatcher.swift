import Foundation
import AppKit
import Network

/// Sleep/wake + network-change handler: при уходе в sleep гарантированно разрываем туннель,
/// при wake — поднимаем заново с ожиданием сети и retry-логикой.
///
/// Watcher активен только если установлен helper — без него reconnect = AppleScript
/// password prompt каждый wake, что хуже чем ничего.
@MainActor
final class NetworkWatcher: ObservableObject {

    /// True пока идёт reconnect-цикл — UI может показать «Reconnecting…».
    @Published private(set) var isRecovering: Bool = false

    private let backend: BackendController
    private let coordinatorFactory: @MainActor () -> ConnectionCoordinator

    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?

    private var wasConnectedBeforeSleep: Bool = false
    private var isReconnecting: Bool = false
    /// Последнее известное состояние пути — обновляется из NWPathMonitor.
    private var lastPathSatisfied: Bool = true

    init(
        backend: BackendController,
        coordinator: @MainActor @escaping () -> ConnectionCoordinator
    ) {
        self.backend = backend
        self.coordinatorFactory = coordinator
    }

    func start() {
        guard willSleepObserver == nil else { return }

        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Assertion берём здесь — синхронно, до Task-диспатча. Иначе macOS может
            // уснуть в окне между выходом из callback и стартом Task на MainActor.
            // ProcessInfo.beginActivity потокобезопасен, вызов из NSWorkspace-треда нормален.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "AwgRoute: dropping VPN before sleep"
            )
            Task { @MainActor in
                defer { ProcessInfo.processInfo.endActivity(activity) }
                await self?.handleWillSleep()
            }
        }

        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in await self?.handleDidWake() }
        }

        startPathMonitor()
    }

    func stop() {
        if let obs = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            willSleepObserver = nil
        }
        if let obs = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            didWakeObserver = nil
        }
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - NWPathMonitor (смена сети без sleep/wake)

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let queue = DispatchQueue(label: "dev.awgroute.netmonitor", qos: .utility)
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasUnsatisfied = !self.lastPathSatisfied
                self.lastPathSatisfied = satisfied
                // Reconnect только если путь восстановился (unsatisfied → satisfied)
                // И backend был running, и не идёт sleep/wake цикл.
                if satisfied && wasUnsatisfied && !self.wasConnectedBeforeSleep && !self.isReconnecting {
                    if case .running = self.backend.status {
                        NSLog("[NetworkWatcher] network recovered → reconnecting")
                        await self.reconnect()
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }

    // MARK: - Sleep / Wake

    private func handleWillSleep() async {
        guard HelperClient.isInstalled else { return }
        guard case .running = backend.status else {
            wasConnectedBeforeSleep = false
            return
        }
        wasConnectedBeforeSleep = true
        NSLog("[NetworkWatcher] willSleep → dropping tunnel")
        await coordinatorFactory().disconnect()
    }

    private func handleDidWake() async {
        guard wasConnectedBeforeSleep else { return }
        wasConnectedBeforeSleep = false
        guard HelperClient.isInstalled else { return }

        NSLog("[NetworkWatcher] didWake → reconnecting")
        await reconnect()
    }

    // MARK: - Reconnect

    private func reconnect() async {
        guard !isReconnecting else { return }
        isReconnecting = true
        isRecovering = true
        defer { isReconnecting = false; isRecovering = false }

        // Ждём usable-путь перед WireGuard handshake; без этого пакеты уходят в void.
        await waitForNetwork(timeout: 30)

        // 3 попытки с экспоненциальным backoff: 0 → 2s → 4s.
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(2_000_000_000) << (attempt - 1))
            }
            await coordinatorFactory().connect()
            if case .running = backend.status { return }
        }
        NSLog("[NetworkWatcher] reconnect: all attempts failed, user must reconnect manually")
    }

    /// Ждём пока NWPathMonitor не скажет satisfied, или пока не истечёт timeout.
    private func waitForNetwork(timeout: TimeInterval) async {
        if lastPathSatisfied { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "dev.awgroute.netwait", qos: .utility)
            var done = false
            monitor.pathUpdateHandler = { path in
                guard !done, path.status == .satisfied else { return }
                done = true
                monitor.cancel()
                cont.resume()
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                monitor.cancel()
                cont.resume()
            }
        }
    }
}
