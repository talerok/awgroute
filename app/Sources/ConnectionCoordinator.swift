import Foundation
import AwgConfig

/// Связывает `ProfileStore` и `BackendController`:
/// материализует активный профиль в JSON-конфиг для amnezia-box и
/// дёргает backend.start/stop. Вынесено отдельно, чтобы UI остался плоским.
@MainActor
struct ConnectionCoordinator {
    let profiles: ProfileStore
    let backend: BackendController
    let rules: RulesStore?

    func connect() async {
        guard let profile = profiles.activeProfile else {
            // Здесь специально не показываем алерт — это инвариант UI: кнопка disabled.
            return
        }
        do {
            let materialized = try profiles.materializedConfig(for: profile)
            var opts = AwgJSONGenerator.Options()
            opts.endpointTag = "vpn"        // зарезервированное имя; rules.json пользователя видит "vpn"
            if let firstDNS = materialized.interface.dns.first {
                opts.remoteDNSServer = firstDNS
            }
            // Если есть валидные пользовательские правила — взять их, иначе минимальный route.
            let userRoute: [String: Any]? = (try? rules?.parsed())
            let json = try AwgJSONGenerator.fullConfigJSON(
                from: materialized,
                options: opts,
                userRoute: userRoute
            )
            try json.write(to: Paths.activeConfig, options: .atomic)
            await backend.start(configPath: Paths.activeConfig.path)
        } catch {
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
