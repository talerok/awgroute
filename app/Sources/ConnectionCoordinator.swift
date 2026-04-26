import Foundation
import AwgConfig

/// Связывает `ProfileStore` и `BackendController`:
/// материализует активный профиль в JSON-конфиг для amnezia-box и
/// дёргает backend.start/stop. Вынесено отдельно, чтобы UI остался плоским.
@MainActor
struct ConnectionCoordinator {
    let profiles: ProfileStore
    let backend: BackendController

    func connect() async {
        guard let profile = profiles.activeProfile else {
            // Здесь специально не показываем алерт — это инвариант UI: кнопка disabled.
            return
        }
        do {
            let materialized = try profiles.materializedConfig(for: profile)
            var opts = AwgJSONGenerator.Options()
            opts.endpointTag = "vpn"        // зарезервированное имя; rules.json пользователя видит "vpn"
            // Если в профиле есть DNS — прокинем как remote
            if let firstDNS = materialized.interface.dns.first {
                opts.remoteDNSServer = firstDNS
            }
            let json = try AwgJSONGenerator.fullConfigJSON(from: materialized, options: opts)
            try json.write(to: Paths.activeConfig, options: .atomic)
            await backend.start(configPath: Paths.activeConfig.path)
        } catch {
            // BackendController.status не выставим напрямую (private set), —
            // выводим в лог, чтобы не молчать.
            NSLog("AwgRoute: connect failed: \(error)")
        }
    }

    func disconnect() async {
        await backend.stop()
    }

    /// Полная переактивация: stop → connect (для случая, когда пользователь
    /// меняет активный профиль во время работы туннеля).
    func switchTo(profile: Profile) async {
        let wasRunning: Bool = {
            if case .running = backend.status { return true }
            return false
        }()
        if wasRunning { await backend.stop() }
        profiles.activeID = profile.id
        if wasRunning { await connect() }
    }
}
