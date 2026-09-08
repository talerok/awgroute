import SwiftUI
import AwgInfrastructure
import AwgPresentation

@main
struct AwgRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var profiles: ProfileStore
    @StateObject private var rules: RulesStore
    @StateObject private var tunnel: TunnelStore
    @StateObject private var logs: LogViewModel
    @StateObject private var telemetry: Telemetry
    @StateObject private var menuBar = MenuBarController()

    private let container: AppContainer

    init() {
        let container = AppContainer()
        self.container = container
        _profiles  = StateObject(wrappedValue: container.profiles)
        _rules     = StateObject(wrappedValue: container.rules)
        _tunnel    = StateObject(wrappedValue: container.tunnel)
        _logs      = StateObject(wrappedValue: container.logs)
        _telemetry = StateObject(wrappedValue: container.telemetry)
    }

    var body: some Scene {
        WindowGroup("AwgRoute") {
            ContentView()
                .environmentObject(profiles)
                .environmentObject(rules)
                .environmentObject(tunnel)
                .environmentObject(logs)
                .environmentObject(telemetry)
                .environmentObject(container.engine)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    appDelegate.tunnel = tunnel
                    menuBar.install(tunnel: tunnel, profiles: profiles)
                    appDelegate.bindTelemetry(tunnel: tunnel, telemetry: telemetry)
                    container.supervisor.start()
                    Task { await container.installer.installOnFirstLaunchIfNeeded() }
                }
        }
        .windowResizability(.contentSize)
    }
}
