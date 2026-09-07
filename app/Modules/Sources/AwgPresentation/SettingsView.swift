import SwiftUI
import AwgDomain

public struct SettingsView: View {
    @EnvironmentObject var tunnel: TunnelStore
    @EnvironmentObject var installerBox: EngineInstallerBox
    @State private var isInstalled: Bool = false
    @State private var isWorking: Bool = false
    @State private var lastError: String?
    @State private var lastSuccess: String?

    public var body: some View {
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
            try await installerBox.installer.install()
            // Пользователь явно нажал Enable — сбрасываем "declined" флаг, чтобы при
            // следующем запуске auto-install опять работал (если helper будет удалён
            // через uninstall).
            installerBox.installer.userDeclined = false
            lastSuccess = "Helper installed. Reconnects will be silent from now on."
        } catch is CancellationError {
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
        // Сначала гасим туннель. Backend спавнится с SETSID и переживает bootout
        // helper'а, а DNS-override снимается только в handleStop — без этого
        // оставался бы root-процесс с подменённым системным DNS и без способа
        // это снять из приложения.
        if tunnel.status.isRunning { await tunnel.disconnect() }
        do {
            try await installerBox.installer.uninstall()
            lastSuccess = "Helper removed."
        } catch is CancellationError {
            // тихо
        } catch {
            lastError = "\(error)"
        }
        refreshState()
        isWorking = false
    }

    private func refreshState() {
        isInstalled = installerBox.installer.isInstalled
    }
}
