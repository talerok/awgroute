import AppKit
import AwgInfrastructure
import AwgPresentation
import Combine
import AwgDomain
import AwgProtocol

/// Три обязанности: single-instance guard, остановка туннеля при выходе,
/// привязка телеметрии к состоянию туннеля.
final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var tunnel: TunnelStore?
    private var bindings: Set<AnyCancellable> = []

    /// Проверяем ДО полного launch, чтобы не создать дубль NSStatusItem и не
    /// перетереть активный конфиг другого инстанса.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.awgroute.app"
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != me
        }
        if let existing = others.first {
            if #available(macOS 14.0, *) { existing.activate() } else { existing.activate(options: []) }
            NSApp.terminate(nil)
        }
    }

    /// Гасим туннель при выходе.
    ///
    /// Оставлять работающий root-процесс с подменённым системным DNS без единого UI,
    /// способного его снять, — худшее из возможных состояний. Раньше именно так и
    /// происходило: функция читала legacy PID-файл, которого в helper-флоу не существует,
    /// и не делала ничего.
    func applicationWillTerminate(_ notification: Notification) {
        guard EngineClient.isInstalled else { return }
        do { _ = try EngineClient.sendSync(.init(command: .stop), timeout: 5) }
        catch { NSLog("[AwgRoute] stop on quit failed: \(error)") }
    }

    /// Не закрывать приложение при закрытии окна — живём в menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for w in sender.windows where w.canBecomeKey {
                w.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }

    @MainActor
    func bindTelemetry(tunnel: TunnelStore, telemetry: Telemetry) {
        bindings.removeAll()
        tunnel.$status
            .receive(on: RunLoop.main)
            .sink { status in
                switch status {
                case .running:            telemetry.start()
                case .stopped, .failed:   telemetry.stop()
                case .starting, .stopping: break
                }
            }
            .store(in: &bindings)
    }
}
