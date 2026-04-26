import SwiftUI

@main
struct AwgRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var backend = BackendController()

    var body: some Scene {
        WindowGroup("AwgRoute") {
            ContentView()
                .environmentObject(backend)
                .frame(minWidth: 600, minHeight: 400)
                .onAppear {
                    appDelegate.backend = backend
                }
        }
        .windowResizability(.contentSize)
    }
}
