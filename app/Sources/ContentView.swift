import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var backend: BackendController
    @State private var configPath: String = defaultConfigPath()
    @State private var logLines: [String] = []
    @State private var logSubscribed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                statusBadge
                Spacer()
                Text(backend.status.label)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Path to amnezia-box config (.json)", text: $configPath)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { browse() }
            }

            HStack {
                Button("Start") {
                    Task { await backend.start(configPath: configPath) }
                }
                .disabled(!canStart)

                Button("Stop") {
                    Task { await backend.stop() }
                }
                .disabled(!canStop)

                Spacer()

                Text(backend.binaryFound ? "Backend: found" : "Backend: NOT FOUND")
                    .font(.caption)
                    .foregroundStyle(backend.binaryFound ? .green : .red)
            }

            Divider()
            Text("Logs (tail)").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .border(.separator)
                .onChange(of: logLines.count) { newValue in
                    if newValue > 0 { proxy.scrollTo(newValue - 1, anchor: .bottom) }
                }
            }
        }
        .padding()
        .task {
            // Один live-подписчик на лог-стрим, пока View жив
            if logSubscribed { return }
            logSubscribed = true
            for await line in backend.logs {
                if logLines.count > 5_000 { logLines.removeFirst(1_000) }
                logLines.append(line)
            }
        }
    }

    private var canStart: Bool {
        if !backend.binaryFound { return false }
        if case .stopped = backend.status { return true }
        if case .error = backend.status   { return true }
        return false
    }
    private var canStop: Bool {
        if case .running = backend.status { return true }
        return false
    }

    private var statusBadge: some View {
        Circle()
            .fill(badgeColor)
            .frame(width: 12, height: 12)
    }
    private var badgeColor: Color {
        switch backend.status {
        case .stopped:           return .gray
        case .starting, .stopping: return .yellow
        case .running:           return .green
        case .error:             return .red
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
        }
    }

    private static func defaultConfigPath() -> String {
        // Удобный дефолт для разработки.
        let candidate = "/Users/artem/Documents/git/vpn-client/tests/configs/test.json"
        if FileManager.default.fileExists(atPath: candidate) { return candidate }
        return ""
    }
}
