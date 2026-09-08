import Foundation
import AwgDomain
import AwgProtocol

/// Реализация `EngineControlling`.
///
/// Перезапуск делается через `launchctl kickstart -k`, а не через bootout: bootout
/// оставил бы систему без движка до следующей установки, потому что `KeepAlive`
/// поднимает его только после падения, а чистый выход перезапуском не считается.
/// Kickstart же гарантированно вернёт демон на место.
public struct EngineControl: EngineControlling {

    public init() {}

    public func health() async -> EngineHealth {
        guard EngineClient.isInstalled else { return EngineHealth(state: .notInstalled) }
        do {
            let response = try await EngineClient.send(.init(command: .status), timeout: 5)
            guard let info = response.engine else {
                // Версия совпала, но сведений нет — так быть не должно.
                return EngineHealth(state: .unreachable("engine reported no diagnostics"))
            }
            return EngineHealth(state: .running(pid: info.pid, uptime: info.uptime, version: info.version))
        } catch EngineClient.Failure.engineReturnedError(let message) {
            // Так выглядит несовпадение версий: движок отвечает, но отказывает.
            return EngineHealth(state: .incompatible(message))
        } catch {
            return EngineHealth(state: .unreachable("\(error)"))
        }
    }

    public func restart() async throws {
        try await AdminShell.run("""
        set -eu
        launchctl kickstart -k system/\(EngineProtocol.Names.daemonLabel)
        """)
    }
}
