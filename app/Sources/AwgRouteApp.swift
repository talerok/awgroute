import SwiftUI

@main
struct AwgRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var backend: BackendController
    @StateObject private var profiles: ProfileStore
    @StateObject private var rules: RulesStore
    @StateObject private var telemetry: Telemetry
    @StateObject private var menuBar = MenuBarController()
    @StateObject private var netWatcher: NetworkWatcher

    init() {
        // NetworkWatcher держит ссылки на backend/coordinator-factory.
        // Создаём в init: @StateObject требует владения объектом до первого body.
        let backend = BackendController()
        let profiles = ProfileStore()
        let rules = RulesStore()
        let telemetry = Telemetry()
        _backend = StateObject(wrappedValue: backend)
        _profiles = StateObject(wrappedValue: profiles)
        _rules = StateObject(wrappedValue: rules)
        _telemetry = StateObject(wrappedValue: telemetry)
        _netWatcher = StateObject(wrappedValue: NetworkWatcher(
            backend: backend,
            coordinator: { ConnectionCoordinator(profiles: profiles, backend: backend, rules: rules) }
        ))
    }

    var body: some Scene {
        WindowGroup("AwgRoute") {
            ContentView()
                .environmentObject(backend)
                .environmentObject(profiles)
                .environmentObject(rules)
                .environmentObject(telemetry)
                .environmentObject(netWatcher)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    appDelegate.backend = backend
                    menuBar.install(backend: backend, profiles: profiles, rules: rules)
                    // Запускать/останавливать telemetry в зависимости от статуса
                    appDelegate.bindTelemetry(backend: backend, telemetry: telemetry)
                    // NetworkWatcher живёт всю жизнь приложения; внутри сам решает,
                    // когда реагировать (только при helper-installed + backend.running).
                    netWatcher.start()
                    // При первом запуске — предложить install helper'а одним системным
                    // промптом пароля. Если пользователь отказался — больше не возвращаемся
                    // (Settings всегда доступны).
                    Task { await HelperInstaller.installOnFirstLaunchIfNeeded() }
                }
        }
        .windowResizability(.contentSize)
    }
}
