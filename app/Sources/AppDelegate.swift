import AppKit
import Combine

/// Минимальный adapter для:
///   1) cleanup amnezia-box при выходе из приложения (NSApplicationDelegate);
///   2) bind телеметрии к статусу backend.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var backend: BackendController?
    private var telemetryBindings: Set<AnyCancellable> = []

    func applicationWillTerminate(_ notification: Notification) {
        backend?.stopBlocking()
    }

    /// Не закрывать приложение при закрытии окна — пусть живёт в menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
