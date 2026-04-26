import AppKit
import Combine

/// Минимальный adapter для:
///   1) cleanup amnezia-box при выходе из приложения (NSApplicationDelegate);
///   2) bind телеметрии к статусу backend;
///   3) single-instance guard.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var backend: BackendController?
    private var telemetryBindings: Set<AnyCancellable> = []

    /// Проверяем ДО полного launch, чтобы не успеть создать NSStatusItem дубликат
    /// и не перетереть active-config.json/PID-файл другого инстанса.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.awgroute.app"
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != me
        }
        if let existing = others.first {
            // .activate() (без options) — современный API; .activateAllWindows
            // deprecated в macOS 14. Для нашего minDeployment=13 проверяем version.
            if #available(macOS 14.0, *) {
                existing.activate()
            } else {
                existing.activate(options: [])
            }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend?.stopBlocking()
    }

    /// Не закрывать приложение при закрытии окна — пусть живёт в menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Клик по dock-иконке (или повторный launch через `open`) когда нет видимых окон —
    /// показать главное окно. Без этого приложение «застревает» в menu bar после ⌘W.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for w in sender.windows where w.canBecomeKey {
                w.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true   // дефолт AppKit: показать существующие окна
    }

    @MainActor
    func bindTelemetry(backend: BackendController, telemetry: Telemetry) {
        telemetryBindings.removeAll()
        backend.$status
            .receive(on: RunLoop.main)
            .sink { status in
                switch status {
                case .running: telemetry.start()
                case .stopped, .error: telemetry.stop()
                default: break
                }
            }
            .store(in: &telemetryBindings)
    }
}
