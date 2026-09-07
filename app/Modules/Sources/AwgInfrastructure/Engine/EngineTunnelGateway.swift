import Foundation
import AwgDomain
import AwgProtocol

/// Реализация `TunnelGateway` поверх сокета движка.
///
/// Конфиг передаётся содержимым, а не путём: владельцем файла стал движок. Это убрало
/// гонку, при которой GUI успевал удалить конфиг раньше, чем backend его открывал,
/// и заодно всю валидацию пути на стороне движка.
public struct EngineTunnelGateway: TunnelGateway {

    public init() {}

    public var isAvailable: Bool { EngineClient.isInstalled }

    public func start(config: Data, dnsServers: [String]) async throws -> TunnelStatus {
        try await send(.init(command: .start,
                             config: String(decoding: config, as: UTF8.self),
                             dnsServers: dnsServers), timeout: 25)
    }

    public func restart(config: Data, dnsServers: [String]) async throws -> TunnelStatus {
        try await send(.init(command: .restart,
                             config: String(decoding: config, as: UTF8.self),
                             dnsServers: dnsServers), timeout: 25)
    }

    public func stop() async throws {
        _ = try await send(.init(command: .stop), timeout: 15)
    }

    public func status() async throws -> TunnelStatus {
        try await send(.init(command: .status), timeout: 5)
    }

    /// Поток состояний от движка. Заменяет опрос: движок сообщает сам, в том числе
    /// о том, чего GUI не спрашивал — например, что backend упал.
    public func events() -> AsyncStream<TunnelStatus> {
        let raw = EngineClient.events()
        return AsyncStream { continuation in
            let task = Task {
                for await state in raw { continuation.yield(Self.status(from: state)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func send(_ request: EngineProtocol.Request, timeout: TimeInterval) async throws -> TunnelStatus {
        do {
            let response = try await EngineClient.send(request, timeout: timeout)
            return Self.status(from: response.state ?? .stopped)
        } catch {
            // Ошибки транспорта переводим в словарь домена: выше по стеку никто
            // не должен знать про сокеты и errno.
            throw TunnelError.gateway("\(error)")
        }
    }

    private static func status(from state: EngineProtocol.State) -> TunnelStatus {
        switch state {
        case .stopped:              return .stopped
        case .running(let pid):     return .running(pid: pid)
        case .failed(let reason):   return .failed(reason)
        }
    }
}
