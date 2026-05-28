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
    /// состояние для последующего restore. Если backup уже существует
    /// (например, smena сети с активным VPN) — overwriting'ом обновляет
    /// и serviceID, и servers, не теряя ранее запомненное original.
    func apply(servers: [String]) throws {
        guard !servers.isEmpty else { return }
        let serviceID = try primaryServiceID()

        // Если backup уже есть — original оставляем тот что есть (не перезаписываем
        // нашими же overridden-значениями). serviceID обновляется на новый primary.
        let original: OriginalState
        if let existing = readBackup() {
            original = existing.original
        } else {
            original = readCurrentState(serviceID: serviceID)
        }

        try saveBackup(Backup(serviceID: serviceID, original: original))
        try setState(serviceID: serviceID, servers: servers)
        flushDNSCache()
        Logger.shared.info("DNS override applied: service=\(serviceID) servers=\(servers)")
    }

    /// Восстановить исходные DNS. No-op если backup'а нет.
    func restore() {
        guard let backup = readBackup() else { return }
        switch backup.original {
        case .noOverride:
            try? removeState(serviceID: backup.serviceID)
        case .hadServers(let s):
            try? setState(serviceID: backup.serviceID, servers: s)
        }
        try? FileManager.default.removeItem(atPath: backupPath)
        flushDNSCache()
        Logger.shared.info("DNS override restored: service=\(backup.serviceID)")
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

    var description: String {
        switch self {
        case .primaryServiceNotFound(let out):
            let preview = out.prefix(200)
            return "primary network service not found in scutil output: \(preview)"
        }
    }
}
