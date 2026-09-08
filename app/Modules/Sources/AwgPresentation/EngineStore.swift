import Foundation
import AwgDomain

/// Состояние движка для UI.
///
/// Отдельно от `TunnelStore`: там состояние ТУННЕЛЯ, здесь — самого демона.
/// Раньше о движке из приложения было известно ровно одно: существует ли файл
/// сокета. Отличить «не установлен», «завис» и «версия не та» было нельзя.
@MainActor
public final class EngineStore: ObservableObject {

    @Published public private(set) var health: EngineHealth = .init(state: .notInstalled)
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastError: String?

    private let control: EngineControlling
    private let installer: EngineInstalling

    public init(control: EngineControlling, installer: EngineInstalling) {
        self.control = control
        self.installer = installer
    }

    public var isInstalled: Bool {
        if case .notInstalled = health.state { return false }
        return true
    }

    public func refresh() async {
        health = await control.health()
    }

    /// Перезапуск демона. Реальный сценарий — движок завис и не отвечает.
    /// Туннель при этом переживёт перезапуск: движок подхватит его через `adopt`.
    public func restart() async {
        await perform { try await control.restart() }
    }

    public func install() async {
        await perform {
            try await installer.install()
            // Явное согласие снимает прошлый отказ: при следующем запуске
            // авто-установка снова имеет смысл.
            installer.userDeclined = false
        }
    }

    public func uninstall() async {
        await perform { try await installer.uninstall() }
    }

    private func perform(_ action: () async throws -> Void) async {
        isBusy = true
        lastError = nil
        do { try await action() }
        catch { lastError = "\(error)" }
        // Дать launchd время поднять демон, иначе увидим его мёртвым сразу после
        // собственного kickstart.
        try? await Task.sleep(for: .seconds(1))
        await refresh()
        isBusy = false
    }
}

public extension EngineHealth.State {
    var title: String {
        switch self {
        case .notInstalled:            return "Not installed"
        case .unreachable:             return "Not responding"
        case .running:                 return "Running"
        case .incompatible:            return "Version mismatch"
        }
    }

    var detail: String? {
        switch self {
        case .notInstalled:
            return nil
        case .unreachable(let why):
            return why
        case .running(let pid, let uptime, let version):
            return "pid \(pid) · up \(Self.formatted(uptime)) · protocol v\(version)"
        case .incompatible(let why):
            return why
        }
    }

    /// Здоров ли движок — для цвета индикатора.
    var isHealthy: Bool {
        if case .running = self { return true }
        return false
    }

    private static func formatted(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = (seconds % 86_400) / 3_600, m = (seconds % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
