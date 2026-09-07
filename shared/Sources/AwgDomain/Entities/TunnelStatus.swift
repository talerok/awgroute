import Foundation

/// Состояние туннеля.
///
/// Единственное определение на весь проект. Раньше состояние жило в трёх местах —
/// в процессе backend'а, в helper'е и в `BackendController` приложения — и почти все
/// баги вида «UI показывает Running при мёртвом туннеле» росли именно из их
/// рассинхрона. Теперь владелец состояния один (helper), а это — его словарь.
public enum TunnelStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(pid: Int32)
    case stopping
    case failed(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Идёт ли сейчас переход. В переходных состояниях команды управления
    /// не принимаются — это инвариант, а не решение UI.
    public var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: return true
        case .stopped, .running, .failed: return false
        }
    }
}

/// Ошибки уровня сценариев. Текст предназначен пользователю.
public enum TunnelError: Error, Equatable, LocalizedError, Sendable {
    case noActiveProfile
    case secretMissing(profileName: String, what: String)
    case invalidRules(String)
    case configRejected(String)
    case gateway(String)

    public var errorDescription: String? {
        switch self {
        case .noActiveProfile:
            return "No active profile selected."
        case .secretMissing(let name, let what):
            return "\(what) for '\(name)' is missing from the Keychain. Re-import the profile."
        case .invalidRules(let detail):
            return "rules.json is invalid: \(detail)"
        case .configRejected(let detail):
            return "Backend rejected the configuration: \(detail)"
        case .gateway(let detail):
            return detail
        }
    }
}

public extension TunnelStatus {
    /// Человекочитаемая подпись для UI.
    var label: String {
        switch self {
        case .stopped:        return "Stopped"
        case .starting:       return "Starting…"
        case .running(let p): return "Running (pid \(p))"
        case .stopping:       return "Stopping…"
        case .failed(let m):  return "Error: \(m)"
        }
    }
}
