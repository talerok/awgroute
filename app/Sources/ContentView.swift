import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            TunnelView()
                .tabItem { Label("Tunnel", systemImage: "network") }
            RulesEditorView()
                .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
