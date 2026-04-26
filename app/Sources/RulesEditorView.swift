import SwiftUI

struct RulesEditorView: View {
    @EnvironmentObject var rules: RulesStore
    @EnvironmentObject var backend: BackendController
    @EnvironmentObject var profiles: ProfileStore
    @State private var applyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(RulesStore.presets) { preset in
                        Button(preset.name) { rules.load(preset: preset) }
                    }
                } label: {
                    Label("Insert template", systemImage: "doc.text")
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 200)

                Button("Format") { rules.format() }
                Button("Revert") { rules.revert() }

                Spacer()

                statusLabel

                Button("Apply") { Task { await apply() } }
                    .keyboardShortcut("s", modifiers: [.command])
                    .controlSize(.large)
                    .disabled(!canApply)
            }

            TextEditor(text: $rules.text)
                .font(.system(.body, design: .monospaced))
                .border(.separator)
                .background(Color(NSColor.textBackgroundColor))
        }
        .padding()
        .alert("Apply failed",
               isPresented: Binding(get: { applyError != nil }, set: { if !$0 { applyError = nil } }),
               presenting: applyError) { _ in
            Button("OK") { applyError = nil }
        } message: { msg in Text(msg) }
    }

    private var canApply: Bool {
        if case .error = rules.validation { return false }
        if !backend.binaryFound { return false }
        return true
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch rules.validation {
        case .ok:
            Label("Valid JSON", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .error(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(1)
        }
    }

    private func apply() async {
        do {
            try rules.save()
        } catch {
            applyError = "Save failed: \(error.localizedDescription)"
            return
        }
        // Перезапуск backend, если активный профиль есть и туннель работает
        guard profiles.activeProfile != nil else { return }
        let coord = ConnectionCoordinator(profiles: profiles, backend: backend, rules: rules)
        if case .running = backend.status {
            await coord.disconnect()
            await coord.connect()
        }
    }
}
