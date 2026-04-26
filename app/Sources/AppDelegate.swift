import AppKit

/// Глобальная ссылка на backend, чтобы можно было остановить его при выходе из приложения.
/// SwiftUI App не даёт удобного способа поймать NSApplication.willTerminateNotification
/// без NSApplicationDelegate, поэтому делаем минимальный adapter.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    weak var backend: BackendController?

    func applicationWillTerminate(_ notification: Notification) {
        // Синхронно — иначе процесс может остаться висеть.
        backend?.stopBlocking()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
