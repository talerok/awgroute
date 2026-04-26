import SwiftUI

struct SettingsView: View {
    @State private var isInstalled: Bool = false
    @State private var isWorking: Bool = false
    @State private var lastError: String?
    @State private var lastSuccess: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(isInstalled ? "Enabled" : "Disabled")
                        .foregroundStyle(isInstalled ? .green : .secondary)
                }

                if isInstalled {
                    Button("Disable silent reconnect", role: .destructive) {
                        Task { await disable() }
                    }
                    .disabled(isWorking)
                } else {
                    Button("Enable silent reconnect…") {
                        Task { await enable() }
                    }
                    .disabled(isWorking)
                }

                if isWorking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundStyle(.secondary).font(.caption)
                    }
                }
                if let err = lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let ok = lastSuccess {
                    Text(ok)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Silent reconnect")
            } footer: {
                Text("""
                Installs a small privileged helper that lets AwgRoute reconnect after sleep/wake or network changes without prompting for your password every time.

                You'll be asked for your admin password once during install. The helper runs as a launchd daemon under `/Library/LaunchDaemons/`. Click "Disable" to remove it completely.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 240)
        .onAppear { refreshState() }
    }

    // MARK: - Actions

    private func enable() async {
        isWorking = true
        lastError = nil
        lastSuccess = nil
        do {
            try await HelperInstaller.install()
            // Пользователь явно нажал Enable — сбрасываем "declined" флаг, чтобы при
            // следующем запуске auto-install опять работал (если helper будет удалён
            // через uninstall).
            HelperInstaller.userDeclined = false
            lastSuccess = "Helper installed. Reconnects will be silent from now on."
        } catch HelperInstaller.InstallError.userCancelled {
            // Молча — пользователь отменил, это нормальный сценарий.
        } catch {
            lastError = "\(error)"
        }
        refreshState()
        isWorking = false
    }

    private func disable() async {
        isWorking = true
        lastError = nil
        lastSuccess = nil
        do {
            try await HelperInstaller.uninstall()
            lastSuccess = "Helper removed."
        } catch HelperInstaller.InstallError.userCancelled {
            // тихо
        } catch {
            lastError = "\(error)"
        }
        refreshState()
        isWorking = false
    }

    private func refreshState() {
        isInstalled = HelperClient.isInstalled
    }
}
