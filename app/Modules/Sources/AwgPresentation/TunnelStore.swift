import Foundation
import AwgDomain

/// Состояние туннеля для UI.
///
/// Зеркало, а не источник истины: владелец состояния — helper, сюда оно приходит через
/// `TunnelGateway.status()`. Зависит только от домена: ни файлов, ни путей, ни знания
/// о том, где лежит бинарь backend'а — всё за портами.
@MainActor
public final class TunnelStore: ObservableObject {

    @Published public private(set) var status: TunnelStatus = .stopped
    public let backendAvailable: Bool

    private let gateway: TunnelGateway
    private let connectTunnel: ConnectTunnel
    private let disconnectTunnel: DisconnectTunnel
    private let logs: LogSource
    private var eventTask: Task<Void, Never>?

    public init(
        gateway: TunnelGateway,
        connect: ConnectTunnel,
        disconnect: DisconnectTunnel,
        logs: LogSource,
        availability: BackendAvailability
    ) {
        self.gateway = gateway
        self.connectTunnel = connect
        self.disconnectTunnel = disconnect
        self.logs = logs
        self.backendAvailable = availability.isBackendPresent
        subscribeToEngine()
    }

    deinit { eventTask?.cancel() }

    // MARK: - Команды

    public func connect(profile: Profile?) async { await run(profile: profile, mode: .start) }

    /// Переподнять туннель, даже если он уже `.running`: при восстановлении сети
    /// процесс жив, и обычный connect был бы no-op.
    public func reconnect(profile: Profile?) async { await run(profile: profile, mode: .restart) }

    public func disconnect() async {
        guard !status.isTransitioning else { return }
        status = .stopping
        do {
            try await disconnectTunnel()
            status = .stopped
        } catch {
            status = .failed(message(for: error))
        }
    }

    /// Применить результат переподключения, выполненного супервизором.
    public func apply(_ newStatus: TunnelStatus) { status = newStatus }

    /// Явная сверка с движком. Обычно достаточно событий; это — на случай,
    /// когда состояние нужно узнать здесь и сейчас.
    public func refresh() async {
        guard gateway.isAvailable, let actual = try? await gateway.status() else { return }
        guard !status.isTransitioning, actual != status else { return }
        status = actual
    }

    // MARK: - Private

    private func run(profile: Profile?, mode: ConnectTunnel.Mode) async {
        guard !status.isTransitioning else { return }
        status = .starting
        logs.start()
        do {
            status = try await connectTunnel(profile: profile, mode: mode)
            subscribeToEngine()
        } catch {
            status = .failed(message(for: error))
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// Подписка на состояния движка.
    ///
    /// Заменяет прежний опрос раз в пять секунд. Движок сообщает о переходах сам —
    /// в том числе о тех, о которых его не спрашивали: упавший backend виден сразу,
    /// а не через полпериода опроса. Обрыв потока (движок перезапустился) переподнимаем.
    private func subscribeToEngine() {
        guard gateway.isAvailable else { return }
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let stream = self?.gateway.events() else { return }
                for await state in stream {
                    guard let self else { return }
                    // Переходное состояние не перетираем: пользователь мог только что
                    // нажать кнопку, и событие о старом состоянии не должно откатывать UI.
                    guard !self.status.isTransitioning else { continue }
                    self.status = state
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
