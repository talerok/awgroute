import Foundation

/// Поднять туннель: собрать конфиг и отдать команду шлюзу.
///
/// Три зависимости вместо восьми — вся подготовка вынесена в `BuildTunnelConfig`.
public struct ConnectTunnel: Sendable {
    public enum Mode: Sendable {
        case start
        /// Применяется, даже если туннель уже `.running`. Нужен при восстановлении
        /// сети: процесс жив, но его сокет смотрит в исчезнувший интерфейс.
        case restart
    }

    private let build: BuildTunnelConfig
    private let gateway: TunnelGateway

    public init(build: BuildTunnelConfig, gateway: TunnelGateway) {
        self.build = build
        self.gateway = gateway
    }

    public func callAsFunction(profile: Profile?, mode: Mode = .start) async throws -> TunnelStatus {
        guard let profile else { throw TunnelError.noActiveProfile }
        let prepared = try await build(profile: profile)

        // Конфиг уезжает содержимым: жизненным циклом файла целиком владеет движок,
        // поэтому гонки «GUI удалил раньше, чем backend открыл» больше не существует.
        do {
            switch mode {
            case .start:
                return try await gateway.start(config: prepared.config,
                                               dnsServers: prepared.dnsServers)
            case .restart:
                return try await gateway.restart(config: prepared.config,
                                                 dnsServers: prepared.dnsServers)
            }
        } catch {
            if let e = error as? TunnelError { throw e }
            throw TunnelError.gateway("\(error)")
        }
    }
}

/// Остановить туннель.
public struct DisconnectTunnel: Sendable {
    private let gateway: TunnelGateway

    public init(gateway: TunnelGateway) {
        self.gateway = gateway
    }

    public func callAsFunction() async throws {
        do { try await gateway.stop() }
        catch { throw TunnelError.gateway("\(error)") }
    }
}
