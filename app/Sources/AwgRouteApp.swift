import SwiftUI

@main
struct AwgRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var backend = BackendController()
    @StateObject private var profiles = ProfileStore()

    var body: some Scene {
        WindowGroup("AwgRoute") {
            ContentView()
                .environmentObject(backend)
                .environmentObject(profiles)
                .frame(minWidth: 800, minHeight: 540)
                .onAppear {
                    appDelegate.backend = backend
                }
        }
        .windowResizability(.contentSize)
    }
}
