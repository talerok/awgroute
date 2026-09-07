import Foundation
import AwgProtocol

/// Разбор запроса, вызов сессии, формирование ответа.
///
/// Валидации пути конфига здесь больше нет — и не может быть: в v2 клиент передаёт
/// содержимое, а не путь. Вместе с ней ушли проверки префикса, симлинков в
/// промежуточных компонентах, TOCTOU и владельца файла: проверять стало нечего.
final class CommandDispatcher {

    private let session: TunnelSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: TunnelSession) {
        self.session = session
    }

    /// Результат обработки: что ответить и надо ли оставить соединение открытым
    /// под поток событий.
    struct Outcome {
        let response: Data
        let subscribe: Bool
    }

    func handle(_ data: Data) -> Outcome {
        let request: EngineProtocol.Request
        do {
            request = try decoder.decode(EngineProtocol.Request.self, from: data)
        } catch {
            return Outcome(response: encode(.init(ok: false, error: "invalid request: \(error)")),
                           subscribe: false)
        }

        guard request.protocolVersion == EngineProtocol.version else {
            // Явный отказ вместо молчаливого игнорирования незнакомых полей —
            // ровно то, на чём когда-то потерялся `dnsServers`.
            Logger.shared.warn("rejecting client with protocol v\(request.protocolVersion)")
            return Outcome(
                response: encode(.init(ok: false,
                                       error: EngineProtocol.versionMismatch(
                                           clientVersion: request.protocolVersion))),
                subscribe: false)
        }

        Logger.shared.info("command: \(request.command.rawValue)")

        switch request.command {
        case .status:
            return Outcome(response: encode(.init(ok: true, state: session.state())), subscribe: false)

        case .stop:
            return Outcome(response: encode(.init(ok: true, state: session.stop())), subscribe: false)

        case .start, .restart:
            guard let configText = request.config, !configText.isEmpty else {
                return Outcome(response: encode(.init(ok: false, error: "config is required")),
                               subscribe: false)
            }
            let config = Data(configText.utf8)
            let dns = request.dnsServers ?? []
            let state = request.command == .start
                ? session.start(config: config, dnsServers: dns)
                : session.restart(config: config, dnsServers: dns)
            if case .failed(let reason) = state {
                return Outcome(response: encode(.init(ok: false, state: state, error: reason)),
                               subscribe: false)
            }
            return Outcome(response: encode(.init(ok: true, state: state)), subscribe: false)

        case .subscribe:
            // Ответ подтверждает подписку и сразу отдаёт текущее состояние,
            // чтобы клиенту не пришлось отдельно спрашивать.
            return Outcome(response: encode(.init(ok: true, state: session.state())), subscribe: true)
        }
    }

    private func encode(_ response: EngineProtocol.Response) -> Data {
        (try? encoder.encode(response)) ?? Data(#"{"protocolVersion":2,"ok":false,"error":"encode failed"}"#.utf8)
    }
}
