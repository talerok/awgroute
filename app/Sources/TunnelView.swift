import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Основная вкладка: профили (sidebar) + детали активного (detail).
/// Раньше это был ContentView, выделено в отдельный файл при добавлении TabView.
struct TunnelView: View {
    @EnvironmentObject var backend: BackendController
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var rules: RulesStore
    @EnvironmentObject var telemetry: Telemetry
    @State private var importError: String?
    @State private var deleteError: String?

    var body: some View {
        NavigationSplitView {
            sidebar.frame(minWidth: 220)
        } detail: {
            detail
        }
        .alert("Import failed",
               isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } }),
               presenting: importError) { _ in
            Button("OK") { importError = nil }
        } message: { msg in Text(msg) }
        .alert("Delete failed",
               isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
               presenting: deleteError) { _ in
            Button("OK") { deleteError = nil }
        } message: { msg in Text(msg) }
        .onDrop(of: [.fileURL], isTargeted: nil) { handleDrop(providers: $0) }
    }

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
                        .font(.caption).foregroundStyle(.secondary)
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
                                do { try profiles.delete(p) }
                                catch { deleteError = error.localizedDescription }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importViaPanel() } label: { Label("Import", systemImage: "plus") }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let active = profiles.activeProfile {
            profileDetail(active)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "tray").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Select a profile or import a `.conf` file.")
                    .font(.title3).foregroundStyle(.secondary)
                Button("Import .conf…") { importViaPanel() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .font(.caption).foregroundStyle(backend.binaryFound ? .green : .red)
            }
            .padding(.bottom, 4)

            if case .running = backend.status {
                telemetryStrip
            }

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
            HStack {
                Text("Logs").font(.headline)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(backend.lines.joined(separator: "\n"), forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy all visible log lines")

                Button {
                    NSWorkspace.shared.open(Paths.backendLog)
                } label: { Label("Open file", systemImage: "arrow.up.right.square") }
                .buttonStyle(.borderless)
                .help("Open ~/Library/Logs/AwgRoute/amnezia-box.log")

                Button {
                    backend.clearLines()
                } label: { Label("Clear", systemImage: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Clear visible log buffer")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(backend.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }.padding(8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .border(.separator)
                .onChangeCompat(of: backend.lines.count) { newValue in
                    if newValue > 0 { proxy.scrollTo(newValue - 1, anchor: .bottom) }
                }
            }
            .frame(minHeight: 160)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var telemetryStrip: some View {
        HStack(spacing: 24) {
            telemetryItem("External IP", telemetry.externalIP ?? "…")
            telemetryItem("Uptime",      Telemetry.formatUptime(telemetry.uptime))
            telemetryItem("Down",        Telemetry.formatBytesPerSec(telemetry.downBps))
            telemetryItem("Up",          Telemetry.formatBytesPerSec(telemetry.upBps))
            Spacer()
            Button {
                telemetry.refreshExternalIP()
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless)
            .help("Refresh external IP")
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func telemetryItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced))
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

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
        case .running:  return "Disconnect"
        case .starting: return "Connecting…"
        case .stopping: return "Stopping…"
        default:        return "Connect"
        }
    }
    private var statusBadge: some View { Circle().fill(badgeColor).frame(width: 12, height: 12) }
    private var badgeColor: Color {
        switch backend.status {
        case .stopped:           return .gray
        case .starting, .stopping: return .yellow
        case .running:           return .green
        case .error:             return .red
        }
    }
    private func coordinator() -> ConnectionCoordinator {
        ConnectionCoordinator(profiles: profiles, backend: backend, rules: rules)
    }

    private func importViaPanel() {
        let panel = NSOpenPanel()
        // Любой файл — фильтрация по содержимому, а не по UTType: WireGuard .conf
        // не имеет canonical UTI, а `.text` его тоже не покрывает на macOS 13+.
        var types: [UTType] = [.data, .plainText]
        if let conf = UTType(filenameExtension: "conf") { types.append(conf) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { doImport(url: url) }
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

// MARK: - onChange backport
// macOS 13: onChange(of:perform:) — deprecated in macOS 14.
// macOS 14+: onChange(of:) { old, new in } — new two-parameter form.
private extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, _ action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, new in action(new) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}
