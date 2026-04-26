import SwiftUI

@main
struct AwgRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var backend = BackendController()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var rules = RulesStore()
    @StateObject private var telemetry = Telemetry()
    @StateObject private var menuBar = MenuBarController()

    var body: some Scene {
        WindowGroup("AwgRoute") {
            ContentView()
                .environmentObject(backend)
                .environmentObject(profiles)
                .environmentObject(rules)
                .environmentObject(telemetry)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    appDelegate.backend = backend
                    menuBar.install(backend: backend, profiles: profiles, rules: rules)
                    // Запускать/останавливать telemetry в зависимости от статуса
                    appDelegate.bindTelemetry(backend: backend, telemetry: telemetry)
                }
        }
        .windowResizability(.contentSize)
    }
}
