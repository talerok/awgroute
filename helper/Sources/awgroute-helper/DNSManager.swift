import Foundation
import Darwin

/// Подменяет system DNS на серверы из активного VPN-профиля. Цель:
/// 1. macOS-приложения (Chrome, Safari, и т.д.) идут через VPN-DNS, а не ISP'шный.
/// 2. Apple iCloud Private Relay автоматически выключается при «нестандартном» DNS,
///    поэтому не подменяет результаты резолвинга на свои edge-endpoints.
///
/// Реализация: scutil-overrides на `State:/Network/Service/<primary>/DNS`.
/// State — runtime-only namespace, сбрасывается на reboot: если helper упал
/// с применённым override и не успел restore, пользователь не остаётся «без DNS»
/// после следующей перезагрузки.
///
/// Backup исходного состояния хранится в /var/db/awgroute-helper/dns-backup.json
/// для восстановления при stop и для cleanup'а orphan-override'ов при старте helper'а.
final class DNSManager {

    private let backupPath = "/var/db/awgroute-helper/dns-backup.json"

    /// Состояние DNS до override'а — нужно знать, восстанавливать конкретный
    /// набор серверов или удалять State-запись полностью (был DHCP).
    private enum OriginalState: Codable {
        case noOverride                // в State:/...DNS не было записи (DHCP-based)
        case hadServers([String])      // были явные ServerAddresses
    }

    private struct Backup: Codable {
        let serviceID: String
        let original: OriginalState
    }

    /// Применить DNS-серверы к primary network service. Запоминает исходное
    /// состояние для последующего restore.
    ///
    /// Безопасность: каждый сервер валидируется через `inet_pton` как IPv4/IPv6.
    /// Невалидные отбрасываются — иначе адрес с `\n` или другим control-char'ом
    /// инжектится в scutil-DSL ("d.add ServerAddresses * <addr>") и помощник
    /// выполнит произвольные scutil-команды. Helper не должен доверять app —
    /// app получает DNS из импортированных .conf-профилей, потенциально
    /// злонамеренных.
    ///
    /// Смена сети (primary service ID меняется): сначала восстанавливаем
    /// override на старом service (иначе там останется наш DNS до reboot'а),
    /// потом записываем backup для нового и применяем override на нём.
    func apply(servers: [String]) throws {
        let validated = servers.filter { Self.isValidDNSAddress($0) }
        guard !validated.isEmpty else {
            throw DNSError.noValidServers(input: servers)
        }
        let serviceID = try primaryServiceID()

        let original: OriginalState
        if let existing = readBackup() {
            if existing.serviceID == serviceID {
                // Тот же primary — original оставляем как есть (не перезаписываем
                // нашими же overridden-значениями, если apply вызвали повторно).
                original = existing.original
            } else {
                // Сменился primary (Wi-Fi → Ethernet и т.п.) — откатываем
                // override на старом service, чтобы он не остался застрявшим
                // там после disconnect/reboot.
                Logger.shared.info("primary service changed \(existing.serviceID) → \(serviceID), restoring old override")
                restoreOnService(serviceID: existing.serviceID, original: existing.original)
                // Дальше для нового service читаем current state как baseline.
                original = readCurrentState(serviceID: serviceID)
            }
        } else {
            original = readCurrentState(serviceID: serviceID)
        }

        try saveBackup(Backup(serviceID: serviceID, original: original))
        try setState(serviceID: serviceID, servers: validated)
        flushDNSCache()
        Logger.shared.info("DNS override applied: service=\(serviceID) servers=\(validated)")
    }

    /// Восстановить исходные DNS. No-op если backup'а нет.
    func restore() {
        guard let backup = readBackup() else { return }
        restoreOnService(serviceID: backup.serviceID, original: backup.original)
        try? FileManager.default.removeItem(atPath: backupPath)
        flushDNSCache()
        Logger.shared.info("DNS override restored: service=\(backup.serviceID)")
    }

    /// Восстановить состояние конкретного service'а — без удаления backup-файла
    /// и без flush'а кеша (вызывающий решает). Используется из apply при смене
    /// primary service и из restore().
    private func restoreOnService(serviceID: String, original: OriginalState) {
        switch original {
        case .noOverride:
            try? removeState(serviceID: serviceID)
        case .hadServers(let s):
            try? setState(serviceID: serviceID, servers: s)
        }
    }

    /// Валидация IP-адреса через inet_pton. Безопасна против injection в scutil-DSL:
    /// невалидные строки (с newline, control-chars, посторонним текстом) inet_pton
    /// отвергает. IPv4 и IPv6 оба поддерживаются.
    private static func isValidDNSAddress(_ s: String) -> Bool {
        // inet_pton — строгий парсер, но дополнительная защита от пустых строк
        // и от "тихих" пропусков символов через UTF-8 nil-byte.
        guard !s.isEmpty, !s.contains("\0") else { return false }
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        if s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
        return false
    }

    /// Вызывается при старте helper'а. Если есть backup, но backend не запущен —
    /// значит был неконтролируемый crash или kill, восстанавливаем исходный DNS.
    /// Иначе пользователь после ребута helper'а оказался бы с «застрявшим» override'ом,
    /// который не сбросится пока reboot не случится.
    func cleanupOrphanIfBackendDead(_ backendIsAlive: Bool) {
        guard !backendIsAlive, readBackup() != nil else { return }
        Logger.shared.warn("found orphan DNS backup with no live backend — restoring")
        restore()
    }

    // MARK: - scutil wrapper

    /// `scutil` показывает primary IPv4 service в `State:/Network/Global/IPv4`.
    /// Парсим из строки вида `PrimaryService : ABCDEF-...`.
    private func primaryServiceID() throws -> String {
        let out = try runScutil("show State:/Network/Global/IPv4\n")
        for raw in out.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            // Формат: "PrimaryService : UUID-STR"
            guard s.hasPrefix("PrimaryService") else { continue }
            let parts = s.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        throw DNSError.primaryServiceNotFound(scutilOutput: out)
    }

    /// Текущее содержимое State:/Network/Service/<id>/DNS.
    /// Возвращает noOverride если ключа нет (распространённый случай: DNS от DHCP).
    private func readCurrentState(serviceID: String) -> OriginalState {
        let out = (try? runScutil("show State:/Network/Service/\(serviceID)/DNS\n")) ?? ""
        if out.contains("No such key") || out.trimmingCharacters(in: .whitespaces).isEmpty {
            return .noOverride
        }
        // Формат:
        //   <dictionary> {
        //     ServerAddresses : <array> {
        //       0 : 192.168.3.1
        //     }
        //   }
        var servers: [String] = []
        var inArray = false
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ServerAddresses") { inArray = true; continue }
            guard inArray else { continue }
            if line == "}" { break }
            // "0 : 1.2.3.4"
            if let v = line.split(separator: ":", maxSplits: 1).last {
                let addr = v.trimmingCharacters(in: .whitespaces)
                if !addr.isEmpty { servers.append(addr) }
            }
        }
        return servers.isEmpty ? .noOverride : .hadServers(servers)
    }

    private func setState(serviceID: String, servers: [String]) throws {
        // d.init / d.add / set — стандартная scutil-последовательность для записи в
        // State namespace. ServerAddresses — массив, `*` означает «применить ко всем
        // значениям из последующих аргументов».
        let addresses = servers.joined(separator: " ")
        let script = """
        d.init
        d.add ServerAddresses * \(addresses)
        set State:/Network/Service/\(serviceID)/DNS
        quit

        """
        _ = try runScutil(script)
    }

    private func removeState(serviceID: String) throws {
        _ = try runScutil("remove State:/Network/Service/\(serviceID)/DNS\nquit\n")
    }

    private func runScutil(_ input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        if let data = input.data(using: .utf8) {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? inputPipe.fileHandleForWriting.close()
        let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// dscacheutil + mDNSResponder SIGHUP — иначе старые ответы от ISP-DNS будут
    /// торчать в кеше резолвера, и сайты не подключатся до естественного TTL-expiry.
    private func flushDNSCache() {
        runSilently(path: "/usr/bin/dscacheutil", args: ["-flushcache"])
        runSilently(path: "/usr/bin/killall", args: ["-HUP", "mDNSResponder"])
    }

    private func runSilently(path: String, args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            Logger.shared.warn("\(path) failed: \(error)")
        }
    }

    // MARK: - Backup file

    private func saveBackup(_ backup: Backup) throws {
        let dir = (backupPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }
        let data = try JSONEncoder().encode(backup)
        try data.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupPath
        )
    }

    private func readBackup() -> Backup? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: backupPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(Backup.self, from: data)
    }
}

enum DNSError: Error, CustomStringConvertible {
    case primaryServiceNotFound(scutilOutput: String)
    case noValidServers(input: [String])

    var description: String {
        switch self {
        case .primaryServiceNotFound(let out):
            let preview = out.prefix(200)
            return "primary network service not found in scutil output: \(preview)"
        case .noValidServers(let input):
            return "no valid IPv4/IPv6 addresses among DNS servers: \(input)"
        }
    }
}
