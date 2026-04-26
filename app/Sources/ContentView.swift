import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var backend: BackendController
    @EnvironmentObject var profiles: ProfileStore
    @State private var logLines: [String] = []
    @State private var logSubscribed = false
    @State private var importError: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 220)
        } detail: {
            detail
        }
        .navigationTitle("AwgRoute")
        .alert("Import failed",
               isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } }),
               presenting: importError) { _ in
            Button("OK") { importError = nil }
        } message: { msg in
            Text(msg)
        }
        .task {
            if logSubscribed { return }
            logSubscribed = true
            for await line in backend.logs {
                if logLines.count > 5_000 { logLines.removeFirst(1_000) }
                logLines.append(line)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { profiles.activeID },
            set: { id in
                guard let id = id, let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
                Task { await coordinator().switchTo(profile: profile) }
            }
        )) {
            Section("Profiles") {
                if profiles.profiles.isEmpty {
                    Text("No profiles. Import a `.conf` file →")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles.profiles) { p in
                        HStack {
                            Image(systemName: profiles.activeID == p.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(profiles.activeID == p.id ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(p.name).font(.body)
                                if let firstAddr = p.config.interface.address.first {
                                    Text(firstAddr).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tag(p.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                try? profiles.delete(p)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importViaPanel() } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let active = profiles.activeProfile {
            profileDetail(active)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "tray")
                    .font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Select a profile or import a `.conf` file.")
                    .font(.title3).foregroundStyle(.secondary)
                Button("Import .conf…") { importViaPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func profileDetail(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(profile.name).font(.title)
                Spacer()
                statusBadge.padding(.trailing, 4)
                Text(backend.status.label).foregroundStyle(.secondary)
            }

            HStack {
                Button(connectLabel) {
                    Task {
                        if isRunning { await coordinator().disconnect() }
                        else         { await coordinator().connect() }
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canToggle)
                .controlSize(.large)

                Text(backend.binaryFound ? "Backend OK" : "Backend missing — run backend/build.sh")
                    .font(.caption)
                    .foregroundStyle(backend.binaryFound ? .green : .red)
            }
            .padding(.bottom, 4)

            GroupBox("Interface") {
                VStack(alignment: .leading, spacing: 4) {
                    field("Address", profile.config.interface.address.joined(separator: ", "))
                    field("Private key", profile.maskedPrivateKey)
                    if !profile.config.interface.dns.isEmpty {
                        field("DNS", profile.config.interface.dns.joined(separator: ", "))
                    }
                    if let mtu = profile.config.interface.mtu { field("MTU", String(mtu)) }
                    if let jc = profile.config.interface.jc {
                        field("AWG", "Jc=\(jc), Jmin=\(profile.config.interface.jmin ?? 0), Jmax=\(profile.config.interface.jmax ?? 0)")
                    }
                }
            }

            ForEach(Array(profile.config.peers.enumerated()), id: \.offset) { _, peer in
                GroupBox("Peer") {
                    VStack(alignment: .leading, spacing: 4) {
                        field("Endpoint", "\(peer.endpointHost):\(peer.endpointPort)")
                        field("Public key", Profile.mask(peer.publicKey))
                        if peer.presharedKey != nil { field("Preshared key", "(stored in Keychain)") }
                        field("AllowedIPs", peer.allowedIPs.joined(separator: ", "))
                        if let ka = peer.persistentKeepalive { field("Keepalive", "\(ka)s") }
                    }
                }
            }

            Divider()
            Text("Logs").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }.padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .border(.separator)
                .onChange(of: logLines.count) { newValue in
                    if newValue > 0 { proxy.scrollTo(newValue - 1, anchor: .bottom) }
                }
            }
            .frame(minHeight: 160)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    // MARK: - Helpers

    private var isRunning: Bool { if case .running = backend.status { return true } else { return false } }

    private var canToggle: Bool {
        if !backend.binaryFound { return false }
        switch backend.status {
        case .stopped, .running, .error: return profiles.activeProfile != nil
        case .starting, .stopping:       return false
        }
    }

    private var connectLabel: String {
        switch backend.status {
        case .running: return "Disconnect"
        case .starting: return "Connecting…"
        case .stopping: return "Stopping…"
        default:        return "Connect"
        }
    }

    private var statusBadge: some View {
        Circle().fill(badgeColor).frame(width: 12, height: 12)
    }
    private var badgeColor: Color {
        switch backend.status {
        case .stopped:           return .gray
        case .starting, .stopping: return .yellow
        case .running:           return .green
        case .error:             return .red
        }
    }

    private func coordinator() -> ConnectionCoordinator {
        ConnectionCoordinator(profiles: profiles, backend: backend)
    }

    // MARK: - Import

    private func importViaPanel() {
        let panel = NSOpenPanel()
        if let conf = UTType("public.conf-source-code") {
            panel.allowedContentTypes = [conf, .text]
        } else {
            panel.allowedContentTypes = [.text]
        }
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            doImport(url: url)
        }
    }

    private func doImport(url: URL) {
        do {
            let p = try profiles.importConf(at: url)
            if profiles.activeID == nil { profiles.activeID = p.id }
        } catch {
            importError = "\(error.localizedDescription)\n\n\(error)"
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for prov in providers {
            _ = prov.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                Task { @MainActor in self.doImport(url: url) }
            }
            handled = true
        }
        return handled
    }
}
