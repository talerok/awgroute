import SwiftUI

@main
struct AwgRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var backend = BackendController()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var rules = RulesStore()

    var body: some Scene {
        WindowGroup("AwgRoute") {
            ContentView()
                .environmentObject(backend)
                .environmentObject(profiles)
                .environmentObject(rules)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    appDelegate.backend = backend
                }
        }
        .windowResizability(.contentSize)
    }
}
