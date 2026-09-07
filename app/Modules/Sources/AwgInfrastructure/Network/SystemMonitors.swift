import Foundation
import AppKit
import Network
import AwgDomain

/// Реализация `NetworkMonitoring` на NWPathMonitor.
public final class SystemNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    public init() {}


    private let queue = DispatchQueue(label: "dev.awgroute.netmonitor", qos: .utility)
    private let lock = NSLock()
    private var lastSatisfied = true

    /// Последнее известное состояние пути — читается синхронно, чтобы не ждать
    /// первого события монитора.
    public var isPathSatisfied: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastSatisfied
    }

    public func pathUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied
                self?.lock.lock()
                self?.lastSatisfied = satisfied
                self?.lock.unlock()
                continuation.yield(satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }

    public func waitForPath(timeout: TimeInterval) async -> Bool {
        if isPathSatisfied { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                for await satisfied in self.pathUpdates() where satisfied { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

/// Реализация `PowerMonitoring` на уведомлениях NSWorkspace.
public final class SystemPowerMonitor: PowerMonitoring, @unchecked Sendable {
    public init() {}


    public func events() -> AsyncStream<PowerEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let sleepObserver = center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
            ) { _ in
                // Assertion берём синхронно, до диспатча: иначе macOS успевает уснуть
                // в окне между выходом из колбэка и обработкой события.
                let activity = ProcessInfo.processInfo.beginActivity(
                    options: .idleSystemSleepDisabled, reason: "AwgRoute: dropping VPN before sleep")
                continuation.yield(.willSleep)
                // Держим ассершн недолго: нам нужно лишь успеть послать stop.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    ProcessInfo.processInfo.endActivity(activity)
                }
            }
            let wakeObserver = center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { _ in continuation.yield(.didWake) }

            continuation.onTermination = { _ in
                center.removeObserver(sleepObserver)
                center.removeObserver(wakeObserver)
            }
        }
    }
}
