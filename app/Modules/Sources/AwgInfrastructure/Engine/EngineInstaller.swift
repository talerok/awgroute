import Foundation
import AppKit
import Darwin
import CryptoKit
import AwgProtocol
import AwgDomain

/// Установка/деинсталляция awgroute-engine. Один AppleScript-prompt при enable
/// (admin password) — дальше silent reconnect через `EngineClient`.
///
/// Установка идемпотентна: если engine уже стоит, install() сначала bootout'ит его и
/// переустанавливает. Это даёт upgrade-флоу при обновлении app-bundle.
public enum EngineInstaller {

    public enum InstallError: Error, CustomStringConvertible {
        case missingResource(String)
        case userCancelled
        case scriptFailed(String)
        case socketDidNotAppear

        public var description: String {
            switch self {
            case .missingResource(let r):  return "missing bundled resource: \(r)"
            case .userCancelled:           return "cancelled by user"
            case .scriptFailed(let msg):   return "install failed: \(msg)"
            case .socketDidNotAppear:      return "engine installed but socket did not appear within timeout"
            }
        }
    }

    /// Engine-бинарь внутри app-bundle: `AwgRoute.app/Contents/Library/LaunchServices/awgroute-engine`.
    static var bundledEngine: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/awgroute-engine")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Plist-template внутри Resources, с placeholders `{{OWNER_UID}}` / `{{OWNER_USER}}`.
    static var bundledPlistTemplate: URL? {
        return Bundle.main.url(forResource: "dev.awgroute.engine.plist", withExtension: "template")
    }

    static var isInstalled: Bool { EngineClient.isInstalled }

    /// True если пользователь однажды нажал Cancel в auto-install-промпте.
    /// Хранится в UserDefaults; больше не предлагаем при последующих запусках,
    /// но Settings → Enable silent reconnect остаётся доступным.
    static var userDeclined: Bool {
        get { UserDefaults.standard.bool(forKey: "dev.awgroute.engineInstallDeclined") }
        set { UserDefaults.standard.set(newValue, forKey: "dev.awgroute.engineInstallDeclined") }
    }

    /// Запустить install-флоу при старте приложения. Два случая:
    /// 1. Engine не установлен И пользователь не отказывался — пытаемся поставить.
    /// 2. Engine установлен, но бинарь отличается от того что в app-bundle
    ///    (после обновления .dmg). Тогда переустанавливаем — иначе старый engine
    ///    не знает новых команд и приложение работает как будто фикса нет.
    ///    Был реальный случай: пользователь обновил app с v0.2.0 до v0.3.x, engine
    ///    остался от первой установки и тихо игнорировал новую команду `dnsServers`.
    /// Тихо ничего не делает в остальных случаях.
    static func installOnFirstLaunchIfNeeded() async {
        if isInstalled {
            // Engine стоит — проверяем не отстал ли он от bundled-версии.
            guard needsUpgrade() else { return }
            do {
                try await install()
                NSLog("[EngineInstaller] auto-upgrade completed")
            } catch InstallError.userCancelled {
                // На upgrade-кейсе userDeclined НЕ трогаем — это не первый install,
                // и в Settings уже виден установленный engine. Просто оставляем как есть.
                NSLog("[EngineInstaller] auto-upgrade cancelled by user")
            } catch {
                NSLog("[EngineInstaller] auto-upgrade failed: \(error)")
            }
            return
        }
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
            NSLog("[EngineInstaller] auto-install failed: \(error)")
        }
    }

    /// True если SHA256 bundled-бинаря не совпадает с тем что установлен в
    /// /Library/PrivilegedHelperTools/. Возвращает false если что-то не удалось
    /// прочитать — лучше не дёргать пользователя promt'ом из-за лишней
    /// перестраховки.
    private static func needsUpgrade() -> Bool {
        guard let bundled = bundledEngine else { return false }
        let installed = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/awgroute-engine")
        guard
            let bundledHash = sha256(of: bundled),
            let installedHash = sha256(of: installed)
        else {
            return false
        }
        return bundledHash != installedHash
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Установить engine. Один AppleScript-promt с administrator privileges.
    static func install() async throws {
        guard let engineSrc = bundledEngine else {
            throw InstallError.missingResource("Contents/Library/LaunchServices/awgroute-engine")
        }
        guard let templateURL = bundledPlistTemplate else {
            throw InstallError.missingResource("dev.awgroute.engine.plist.template")
        }

        // Подготовить plist с подставленными OWNER_UID/OWNER_USER.
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let uid = getuid()
        let user = NSUserName()
        let plist = template
            .replacingOccurrences(of: "{{OWNER_UID}}", with: "\(uid)")
            .replacingOccurrences(of: "{{OWNER_USER}}", with: user)

        let tmpPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.awgroute.engine.\(UUID().uuidString).plist")
        try plist.write(to: tmpPlist, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpPlist) }

        // Один shell-блок: bootout (если уже стоит) → копирование → bootstrap.
        // Цель — атомарный install/upgrade за один пароль.
        let bash = """
        set -eu
        # Наследие v1: демон назывался helper и жил под другим label. Если его не
        # снести, в системе окажутся два демона, каждый со своим сокетом, и оба
        # будут пытаться управлять backend'ом.
        launchctl bootout system/dev.awgroute.helper 2>/dev/null || true
        rm -f /Library/LaunchDaemons/com.awgroute.helper.plist
        rm -f /Library/PrivilegedHelperTools/awgroute-helper
        rm -f /var/run/awgroute-helper.sock
        rm -rf /var/db/awgroute-helper

        # idempotent: bootout без проверки наличия (|| true)
        launchctl bootout system/dev.awgroute.engine 2>/dev/null || true
        rm -f /var/run/awgroute-engine.sock
        mkdir -p /Library/PrivilegedHelperTools
        cp \(shellQuote(engineSrc.path)) /Library/PrivilegedHelperTools/awgroute-engine
        chown root:wheel /Library/PrivilegedHelperTools/awgroute-engine
        chmod 755 /Library/PrivilegedHelperTools/awgroute-engine
        cp \(shellQuote(tmpPlist.path)) /Library/LaunchDaemons/dev.awgroute.engine.plist
        chown root:wheel /Library/LaunchDaemons/dev.awgroute.engine.plist
        chmod 644 /Library/LaunchDaemons/dev.awgroute.engine.plist
        launchctl bootstrap system /Library/LaunchDaemons/dev.awgroute.engine.plist
        """

        try await runAsAdmin(bash)

        // launchd создаёт сокет до старта engine'а (socket activation), но даём небольшой
        // запас времени на случай задержки.
        var socketAppeared = false
        for _ in 0..<50 {
            if EngineClient.isInstalled { socketAppeared = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard socketAppeared else { throw InstallError.socketDidNotAppear }

        // Прогрев: первая реальная команда запускает Swift-runtime engine'а, что занимает
        // секунды на macOS. Если этот холодный старт случится при first Connect, клиент
        // словит SO_RCVTIMEO. Делаем .status сейчас с большим timeout — после неё engine
        // в memory, последующие команды отвечают за миллисекунды.
        _ = try? await EngineClient.send(.init(command: .status), timeout: 60)
    }

    /// Снести engine полностью.
    static func uninstall() async throws {
        let bash = """
        set -eu
        launchctl bootout system/dev.awgroute.engine 2>/dev/null || true
        rm -f /Library/LaunchDaemons/dev.awgroute.engine.plist
        rm -f /Library/PrivilegedHelperTools/awgroute-engine
        rm -f /var/run/awgroute-engine.sock
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

/// Адаптер порта `EngineInstalling` над статическим `EngineInstaller`.
/// Существует, чтобы Presentation не знала про AppleScript и launchd.
public struct SystemEngineInstaller: EngineInstalling {
    public init() {}
    public var isInstalled: Bool { EngineInstaller.isInstalled }
    public var userDeclined: Bool {
        get { EngineInstaller.userDeclined }
        nonmutating set { EngineInstaller.userDeclined = newValue }
    }
    public func install() async throws { try await EngineInstaller.install() }
    public func uninstall() async throws { try await EngineInstaller.uninstall() }
    public func installOnFirstLaunchIfNeeded() async { await EngineInstaller.installOnFirstLaunchIfNeeded() }
}
