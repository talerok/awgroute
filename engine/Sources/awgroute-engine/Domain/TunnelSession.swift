import Foundation
import AwgProtocol

/// Единственный владелец состояния туннеля.
///
/// Раньше состояние было расщеплено: процесс жил в `BackendManager`, системный DNS —
/// в `DNSManager`, и они рассинхронизировались. Отсюда были orphan-override'ы: процесс
/// умер, а подменённый DNS остался, потому что снимать его было некому.
///
/// Здесь процесс и DNS — две стадии ОДНОЙ операции, и порядок их применения и отката
/// записан в одном месте.
///
/// Активация намеренно выражена списком шагов, а не одним методом: kill-switch,
/// split-DNS и собственные маршруты вклиниваются именно сюда, и добавление шага
/// не должно требовать правки существующих.
final class TunnelSession {

    private let backend: BackendRunning
    private let dns: SystemDNSControlling
    private let vault: ConfigVault
    private let broadcaster: StateBroadcasting
    private let queue = DispatchQueue(label: "dev.awgroute.engine.session")

    private var lastBroadcast: EngineProtocol.State?

    init(backend: BackendRunning,
         dns: SystemDNSControlling,
         vault: ConfigVault,
         broadcaster: StateBroadcasting) {
        self.backend = backend
        self.dns = dns
        self.vault = vault
        self.broadcaster = broadcaster
    }

    /// Подхватить туннель, переживший перезапуск движка, и снять «осиротевший»
    /// DNS-override, если backend его не пережил.
    func adopt() {
        queue.sync {
            backend.adoptExisting()
            dns.cleanupOrphanIfBackendDead(backend.isAlive())
            publish()
        }
    }

    func state() -> EngineProtocol.State {
        queue.sync { currentState() }
    }

    /// Поднять туннель. Идемпотентно: если уже работает — возвращаем текущее состояние.
    func start(config: Data, dnsServers: [String]) -> EngineProtocol.State {
        queue.sync {
            if backend.isAlive(), let pid = backend.currentPID {
                return publish(.running(pid: pid))
            }
            return activate(config: config, dnsServers: dnsServers)
        }
    }

    /// Перезапустить. Отдельная операция, а не stop+start: между ними DNS-override
    /// не снимается, иначе резолвер «моргает» на каждое переподключение.
    func restart(config: Data, dnsServers: [String]) -> EngineProtocol.State {
        queue.sync {
            backend.stop()
            return activate(config: config, dnsServers: dnsServers)
        }
    }

    func stop() -> EngineProtocol.State {
        queue.sync {
            // Порядок обратный активации: сначала процесс, затем системные настройки,
            // затем конфиг. Иначе на короткое время остаётся туннель без DNS.
            backend.stop()
            dns.restore()
            vault.discard()
            return publish(.stopped)
        }
    }

    /// Сверка с реальностью: процесс мог умереть сам.
    /// Вызывается сторожем; расхождение уезжает подписчикам событием.
    func reconcile() {
        queue.sync {
            let state = currentState()
            if case .stopped = state, lastBroadcast?.isRunning == true {
                // Backend не пережил работу — снимаем то, что без него вредно.
                dns.restore()
                vault.discard()
            }
            publish(state)
        }
    }

    // MARK: - Private

    private func activate(config: Data, dnsServers: [String]) -> EngineProtocol.State {
        do {
            // Шаг 1: конфиг на диск (root-only каталог).
            let path = try vault.store(config)

            // Шаг 2: системный DNS — ДО старта backend'а. Иначе первые запросы,
            // включая скачивание rule-set'ов самим backend'ом, уйдут в ISP-резолвер.
            if !dnsServers.isEmpty {
                do { try dns.apply(servers: dnsServers) }
                catch {
                    // Туннель работоспособен и без override'а — не повод падать.
                    Logger.shared.warn("DNS override failed (continuing): \(error)")
                }
            }

            // Шаг 3: процесс.
            let pid = try backend.start(configPath: path)
            return publish(.running(pid: pid))
        } catch {
            // Откат в обратном порядке: не оставляем ни подменённого DNS,
            // ни конфига с приватным ключом.
            dns.restore()
            vault.discard()
            return publish(.failed(reason: "\(error)"))
        }
    }

    private func currentState() -> EngineProtocol.State {
        guard backend.isAlive(), let pid = backend.currentPID else { return .stopped }
        return .running(pid: pid)
    }

    @discardableResult
    private func publish(_ state: EngineProtocol.State? = nil) -> EngineProtocol.State {
        let value = state ?? currentState()
        // Одинаковые состояния подряд не шлём: подписчику нужны переходы.
        if value != lastBroadcast {
            lastBroadcast = value
            broadcaster.broadcast(value)
        }
        return value
    }
}

extension EngineProtocol.State {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
