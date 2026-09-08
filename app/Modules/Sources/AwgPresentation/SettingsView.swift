import SwiftUI
import AwgDomain

public struct SettingsView: View {

    @EnvironmentObject var tunnel: TunnelStore
    @EnvironmentObject var engine: EngineStore

    public init() {}

    public var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(engine.health.state.isHealthy ? Color.green
                                  : engine.isInstalled ? .red : .secondary)
                            .frame(width: 8, height: 8)
                        Text(engine.health.state.title)
                            .foregroundStyle(engine.health.state.isHealthy ? .green : .primary)
                    }
                }

                if let detail = engine.health.state.detail {
                    LabeledContent("Details") {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    if engine.isInstalled {
                        // Перезапуск, а не «убить»: движок выходит чисто, а KeepAlive
                        // поднимает его только после падения — после простой остановки
                        // приложение осталось бы без движка до переустановки.
                        Button("Restart engine") { Task { await engine.restart() } }
                            .disabled(engine.isBusy)
                            .help("Перезапустить демон через launchd. Туннель переживёт: движок подхватит его обратно.")

                        Button("Remove engine", role: .destructive) {
                            Task { await removeEngine() }
                        }
                        .disabled(engine.isBusy)
                    } else {
                        Button("Install engine…") { Task { await engine.install() } }
                            .disabled(engine.isBusy)
                    }

                    if engine.isBusy {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                    }
                }

                if let error = engine.lastError {
                    Text(error)
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("""
                Движок — привилегированный демон, который владеет процессом backend'а \
                и системным DNS. Он работает постоянно, независимо от приложения, \
                и подхватывает туннель обратно после собственного перезапуска.

                Установка запрашивает пароль администратора один раз. Удаление снимает \
                демон целиком: автоматическое переподключение после сна и смены сети \
                перестанет работать.
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 280)
        .task { await engine.refresh() }
    }

    /// Удаление демона при живом туннеле оставило бы root-процесс с подменённым
    /// системным DNS и без способа его снять из приложения.
    private func removeEngine() async {
        if tunnel.status.isRunning { await tunnel.disconnect() }
        await engine.uninstall()
    }
}
