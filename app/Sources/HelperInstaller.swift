import Foundation
import AppKit
import Darwin

/// Установка/деинсталляция awgroute-helper. Один AppleScript-prompt при enable
/// (admin password) — дальше silent reconnect через `HelperClient`.
///
/// Установка идемпотентна: если helper уже стоит, install() сначала bootout'ит его и
/// переустанавливает. Это даёт upgrade-флоу при обновлении app-bundle.
enum HelperInstaller {

    enum InstallError: Error, CustomStringConvertible {
        case missingResource(String)
        case userCancelled
        case scriptFailed(String)
        case socketDidNotAppear

        var description: String {
            switch self {
            case .missingResource(let r):  return "missing bundled resource: \(r)"
            case .userCancelled:           return "cancelled by user"
            case .scriptFailed(let msg):   return "install failed: \(msg)"
            case .socketDidNotAppear:      return "helper installed but socket did not appear within timeout"
            }
        }
    }

    /// Helper-бинарь внутри app-bundle: `AwgRoute.app/Contents/Library/LaunchServices/awgroute-helper`.
    static var bundledHelper: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/awgroute-helper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Plist-template внутри Resources, с placeholders `{{OWNER_UID}}` / `{{OWNER_USER}}`.
    static var bundledPlistTemplate: URL? {
        return Bundle.main.url(forResource: "com.awgroute.helper.plist", withExtension: "template")
    }

    static var isInstalled: Bool { HelperClient.isInstalled }

    /// True если пользователь однажды нажал Cancel в auto-install-промпте.
    /// Хранится в UserDefaults; больше не предлагаем при последующих запусках,
    /// но Settings → Enable silent reconnect остаётся доступным.
    static var userDeclined: Bool {
        get { UserDefaults.standard.bool(forKey: "dev.awgroute.helperInstallDeclined") }
        set { UserDefaults.standard.set(newValue, forKey: "dev.awgroute.helperInstallDeclined") }
    }

    /// Запустить install-флоу один раз при старте приложения, если helper ещё не
    /// установлен И пользователь не отказывался ранее. Вызывается из onAppear.
    /// Тихо ничего не делает в остальных случаях.
    static func installOnFirstLaunchIfNeeded() async {
        if isInstalled { return }
        if userDeclined { return }
        do {
            try await install()
        } catch InstallError.userCancelled {
            // Пользователь нажал Cancel — запоминаем, чтобы не задалбывать.
            // Через Settings всегда можно передумать.
            userDeclined = true
        } catch {
            // Другие ошибки — не трогаем флаг declined, но логируем.
            // Пользователь увидит детали в Settings, если решит попробовать вручную.
            NSLog("[HelperInstaller] auto-install failed: \(error)")
        }
    }

    /// Установить helper. Один AppleScript-promt с administrator privileges.
    static func install() async throws {
        guard let helperSrc = bundledHelper else {
            throw InstallError.missingResource("Contents/Library/LaunchServices/awgroute-helper")
        }
        guard let templateURL = bundledPlistTemplate else {
            throw InstallError.missingResource("com.awgroute.helper.plist.template")
        }

        // Подготовить plist с подставленными OWNER_UID/OWNER_USER.
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let uid = getuid()
        let user = NSUserName()
        let plist = template
            .replacingOccurrences(of: "{{OWNER_UID}}", with: "\(uid)")
            .replacingOccurrences(of: "{{OWNER_USER}}", with: user)

        let tmpPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.awgroute.helper.\(UUID().uuidString).plist")
        try plist.write(to: tmpPlist, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpPlist) }

        // Один shell-блок: bootout (если уже стоит) → копирование → bootstrap.
        // Цель — атомарный install/upgrade за один пароль.
        let bash = """
        set -eu
        # idempotent: bootout без проверки наличия (|| true)
        launchctl bootout system/dev.awgroute.helper 2>/dev/null || true
        rm -f /var/run/awgroute-helper.sock
        mkdir -p /Library/PrivilegedHelperTools
        cp \(shellQuote(helperSrc.path)) /Library/PrivilegedHelperTools/awgroute-helper
        chown root:wheel /Library/PrivilegedHelperTools/awgroute-helper
        chmod 755 /Library/PrivilegedHelperTools/awgroute-helper
        cp \(shellQuote(tmpPlist.path)) /Library/LaunchDaemons/com.awgroute.helper.plist
        chown root:wheel /Library/LaunchDaemons/com.awgroute.helper.plist
        chmod 644 /Library/LaunchDaemons/com.awgroute.helper.plist
        launchctl bootstrap system /Library/LaunchDaemons/com.awgroute.helper.plist
        """

        try await runAsAdmin(bash)

        // launchd создаёт сокет до старта helper'а (socket activation), но даём небольшой
        // запас времени на случай задержки.
        var socketAppeared = false
        for _ in 0..<50 {
            if HelperClient.isInstalled { socketAppeared = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard socketAppeared else { throw InstallError.socketDidNotAppear }

        // Прогрев: первая реальная команда запускает Swift-runtime helper'а, что занимает
        // секунды на macOS. Если этот холодный старт случится при first Connect, клиент
        // словит SO_RCVTIMEO. Делаем .status сейчас с большим timeout — после неё helper
        // в memory, последующие команды отвечают за миллисекунды.
        _ = try? await HelperClient.send(.status, timeout: 60)
    }

    /// Снести helper полностью.
    static func uninstall() async throws {
        let bash = """
        set -eu
        launchctl bootout system/dev.awgroute.helper 2>/dev/null || true
        rm -f /Library/LaunchDaemons/com.awgroute.helper.plist
        rm -f /Library/PrivilegedHelperTools/awgroute-helper
        rm -f /var/run/awgroute-helper.sock
        """
        try await runAsAdmin(bash)
    }

    // MARK: - Private

    private static func runAsAdmin(_ bash: String) async throws {
        let escaped = bash
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        do shell script "\(escaped)" with administrator privileges
        """

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // AppleScript с GUI-промптом не должен выполняться на main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                guard let appleScript = NSAppleScript(source: script) else {
                    cont.resume(throwing: InstallError.scriptFailed("NSAppleScript init failed"))
                    return
                }
                _ = appleScript.executeAndReturnError(&err)
                if let err = err {
                    // -128 = errAEEventCanceled — пользователь нажал Cancel в диалоге пароля.
                    let code = err[NSAppleScript.errorNumber] as? Int ?? 0
                    if code == -128 {
                        cont.resume(throwing: InstallError.userCancelled)
                    } else {
                        let msg = err[NSAppleScript.errorMessage] as? String ?? "code=\(code)"
                        cont.resume(throwing: InstallError.scriptFailed(msg))
                    }
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    /// POSIX shell quoting через одиночные кавычки. Безопасно для путей с пробелами и
    /// спецсимволами; единственное что нельзя — литеральная одинарная кавычка внутри,
    /// поэтому экранируем её через `'\''`.
    private static func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
