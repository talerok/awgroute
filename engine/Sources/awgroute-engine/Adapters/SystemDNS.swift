import Foundation
import Darwin
import AwgProtocol

/// Подменяет system DNS на серверы из активного VPN-профиля. Цель:
/// 1. macOS-приложения (Chrome, Safari, и т.д.) идут через VPN-DNS, а не ISP'шный.
/// 2. Apple iCloud Private Relay автоматически выключается при «нестандартном» DNS,
///    поэтому не подменяет результаты резолвинга на свои edge-endpoints.
///
/// Реализация: scutil-overrides на `Setup:/Network/Service/<primary>/DNS`.
/// Почему Setup, а не State (хотя для VPN-runtime'а вроде логичнее State):
/// - на современной macOS DHCP-клиент периодически перезаписывает
///   `State:/.../DNS` ответом DHCP-сервера (typical TTL ~60 сек) — наш State
///   override живёт минуту и тихо протухает, пользователь видит «опять Chrome
///   виснет на сайтах», как будто override никогда и не применялся;
/// - `Setup:` DHCP-клиент не трогает, mDNSResponder читает его как primary;
/// - scutil `set Setup:...` без `commit` — runtime-only: prefs.plist не меняется,
///   после reboot вернутся исходные настройки из System Settings UI. Это даёт
///   ту же безопасность от «застрявшего» override'а, что и State.
///
/// Backup исходного состояния хранится в /var/db/awgroute-engine/dns-backup.json
/// для восстановления при stop и для cleanup'а orphan-override'ов при старте helper'а.
final class SystemDNS: SystemDNSControlling {

    private let backupPath = EngineProtocol.Paths.dnsBackup

    /// Все операции сериализованы. SocketServer обрабатывает клиентов на concurrent-
    /// очереди, а состояние здесь общее (backup-файл + записи в scutil). Без этого
    /// гонка stop/start рвала инвариант: apply уже прочитал backup, restore его удалил —
    /// override применён, восстановить нечем, и DNS остаётся подменённым до reboot'а.
    private let queue = DispatchQueue(label: "dev.awgroute.helper.dns")

    /// Состояние DNS до override'а — нужно знать, восстанавливать конкретный
    /// набор серверов или удалять Setup-запись полностью (был DHCP).
    private enum OriginalState: Codable {
        case noOverride                // в Setup:/...DNS не было записи (DHCP-based)
        case hadServers([String])      // были явные ServerAddresses
    }

    /// Были ли в исходном словаре ТОЛЬКО SearchDomains, без ServerAddresses.
    /// Такое состояние нельзя восстанавливать через `remove`: снесётся весь словарь
    /// вместе с доменами. Именно этот подслучай остался незакрытым в прошлый раз.
    private static func hasOnlyDomains(_ original: OriginalState, _ domains: [String]?) -> Bool {
        if case .noOverride = original { return !(domains ?? []).isEmpty }
        return false
    }

    private struct Backup: Codable {
        let serviceID: String
        let original: OriginalState
        /// SearchDomains, которые были в том же словаре. Восстанавливаются вместе с
        /// серверами: раньше мы сохраняли только ServerAddresses и писали обратно
        /// тоже только их, так что настроенные пользователем search-домены пропадали
        /// после первого же disconnect.
        ///
        /// Optional и с дефолтом — старые backup-файлы без этого поля декодируются.
        var searchDomains: [String]? = nil
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
        try queue.sync { try applyLocked(servers: servers) }
    }

    private func applyLocked(servers: [String]) throws {
        let validated = servers.filter { Self.isValidDNSAddress($0) }
        guard !validated.isEmpty else {
            throw DNSError.noValidServers(input: servers)
        }
        let serviceID = try primaryServiceID()

        let original: OriginalState
        var searchDomains: [String]?
        if let existing = readBackup() {
            if existing.serviceID == serviceID {
                // Тот же primary — original оставляем как есть (не перезаписываем
                // нашими же overridden-значениями, если apply вызвали повторно).
                original = existing.original
                searchDomains = existing.searchDomains
            } else {
                // Сменился primary (Wi-Fi → Ethernet и т.п.) — откатываем
                // override на старом service, чтобы он не остался застрявшим
                // там после disconnect/reboot.
                Logger.shared.info("primary service changed \(existing.serviceID) → \(serviceID), restoring old override")
                restoreOnService(serviceID: existing.serviceID,
                                 original: existing.original,
                                 searchDomains: existing.searchDomains)
                // Дальше для нового service читаем current state как baseline.
                (original, searchDomains) = readCurrentDNS(serviceID: serviceID)
            }
        } else {
            (original, searchDomains) = readCurrentDNS(serviceID: serviceID)
        }

        try saveBackup(Backup(serviceID: serviceID, original: original, searchDomains: searchDomains))
        // Search-домены сохраняем и во время override'а: они к выбору резолвера
        // отношения не имеют, а их пропажа ломает короткие имена в локальной сети.
        try setDNS(serviceID: serviceID, servers: validated, searchDomains: searchDomains)
        flushDNSCache()
        Logger.shared.info("DNS override applied: service=\(serviceID) servers=\(validated)")
    }

    /// Восстановить исходные DNS. No-op если backup'а нет.
    func restore() {
        queue.sync { restoreLocked() }
    }

    private func restoreLocked() {
        guard let backup = readBackup() else { return }
        let ok = restoreOnService(serviceID: backup.serviceID,
                                  original: backup.original,
                                  searchDomains: backup.searchDomains)
        guard ok else {
            // Backup НЕ удаляем: иначе исходное состояние потеряно навсегда, а
            // cleanupOrphanIfBackendDead при следующем старте уже не починит.
            Logger.shared.warn("keeping DNS backup for retry: restore did not apply")
            return
        }
        try? FileManager.default.removeItem(atPath: backupPath)
        flushDNSCache()
        Logger.shared.info("DNS override restored: service=\(backup.serviceID)")
    }

    /// Восстановить состояние конкретного service'а — без удаления backup-файла
    /// и без flush'а кеша (вызывающий решает). Используется из apply при смене
    /// primary service и из restore().
    /// Возвращает true, если восстановление действительно применилось.
    /// Раньше результат игнорировался, а backup удалялся безусловно — при сбое scutil
    /// исходное состояние терялось навсегда, и следующий apply запоминал как «исходный»
    /// уже наш VPN-DNS.
    @discardableResult
    private func restoreOnService(serviceID: String, original: OriginalState, searchDomains: [String]?) -> Bool {
        do {
            switch original {
            case .noOverride where Self.hasOnlyDomains(original, searchDomains):
                // Серверов не было, а домены были: убираем только серверы, домены
                // возвращаем на место. `remove` снёс бы словарь целиком.
                try setDNS(serviceID: serviceID, servers: [], searchDomains: searchDomains)
            case .noOverride:
                try removeDNS(serviceID: serviceID)
            case .hadServers(let s):
                try setDNS(serviceID: serviceID, servers: s, searchDomains: searchDomains)
            }
            return true
        } catch {
            Logger.shared.error("DNS restore failed for \(serviceID): \(error)")
            return false
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
        queue.sync {
            guard !backendIsAlive, readBackup() != nil else { return }
            Logger.shared.warn("found orphan DNS backup with no live backend — restoring")
            restoreLocked()
        }
    }

    // MARK: - scutil wrapper

    /// `scutil` показывает primary IPv4 service в `State:/Network/Global/IPv4`.
    /// Парсим из строки вида `PrimaryService : ABCDEF-...`.
    private func primaryServiceID() throws -> String {
        // IPv6-only сеть (или момент до получения IPv4-lease) не имеет PrimaryService
        // в IPv4-словаре — раньше это молча оставляло пользователя на ISP-DNS.
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let id = try? primaryServiceID(fromKey: key) { return id }
        }
        throw DNSError.primaryServiceNotFound(scutilOutput: "no PrimaryService in IPv4/IPv6 global state")
    }

    private func primaryServiceID(fromKey key: String) throws -> String {
        let out = try runScutil("show \(key)\n")
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

    /// Текущее содержимое Setup:/Network/Service/<id>/DNS.
    /// Возвращает noOverride если ключа нет (распространённый случай: DNS от DHCP).
    ///
    /// Формат вывода scutil:
    ///   <dictionary> {
    ///     ServerAddresses : <array> {
    ///       0 : 192.168.3.1
    ///     }
    ///     SearchDomains : <array> {
    ///       0 : lan
    ///     }
    ///   }
    private func readCurrentDNS(serviceID: String) -> (OriginalState, [String]?) {
        let out = (try? runScutil("show Setup:/Network/Service/\(serviceID)/DNS\n")) ?? ""
        if out.contains("No such key") || out.trimmingCharacters(in: .whitespaces).isEmpty {
            return (.noOverride, nil)
        }
        var arrays: [String: [String]] = [:]
        var currentArray: String? = nil
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "}" { currentArray = nil; continue }
            // "ServerAddresses : <array> {" — начало массива.
            if line.hasSuffix("{"), let name = line.split(separator: ":").first {
                let key = name.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, key != "<dictionary>" { currentArray = key }
                continue
            }
            // "0 : 1.2.3.4" — элемент. maxSplits: 1, чтобы не порезать IPv6 по ':'.
            guard let name = currentArray,
                  let v = line.split(separator: ":", maxSplits: 1).last else { continue }
            let value = v.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { arrays[name, default: []].append(value) }
        }
        let servers = arrays["ServerAddresses"] ?? []
        let domains = arrays["SearchDomains"]
        return (servers.isEmpty ? .noOverride : .hadServers(servers), domains)
    }

    /// d.init / d.add / set — стандартная scutil-последовательность для записи в
    /// Setup namespace. `*` означает «массив из последующих аргументов».
    private func setDNS(serviceID: String, servers: [String], searchDomains: [String]?) throws {
        var script = "d.init\n"
        if !servers.isEmpty {
            script += "d.add ServerAddresses * \(servers.joined(separator: " "))\n"
        }
        // Домены приходят из scutil-вывода, а не от app, но в scutil-DSL они всё равно
        // подставляются как аргументы — фильтруем всё, что может сломать команду.
        let domains = (searchDomains ?? []).filter { Self.isValidSearchDomain($0) }
        if !domains.isEmpty {
            script += "d.add SearchDomains * \(domains.joined(separator: " "))\n"
        }
        script += "set Setup:/Network/Service/\(serviceID)/DNS\nquit\n"
        _ = try runScutil(script)
    }

    /// Домен для scutil-DSL: только то, что реально может быть DNS-суффиксом.
    /// Пробелы, кавычки, переводы строк и прочее — отвергаем.
    private static func isValidSearchDomain(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private func removeDNS(serviceID: String) throws {
        _ = try runScutil("remove Setup:/Network/Service/\(serviceID)/DNS\nquit\n")
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

        // Таймаут обязателен: подвисший configd (обычное дело при переключении сетей)
        // раньше блокировал воркер навсегда — пользователь не мог даже отключиться.
        let deadline = DispatchTime.now() + .seconds(10)
        let done = DispatchSemaphore(value: 0)
        var outData = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            Logger.shared.error("scutil timed out, killing it")
            process.terminate()
            _ = done.wait(timeout: .now() + .seconds(2))
            throw DNSError.scutilTimedOut
        }
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
    case scutilTimedOut

    var description: String {
        switch self {
        case .primaryServiceNotFound(let out):
            let preview = out.prefix(200)
            return "primary network service not found in scutil output: \(preview)"
        case .noValidServers(let input):
            return "no valid IPv4/IPv6 addresses among DNS servers: \(input)"
        case .scutilTimedOut:
            return "scutil did not finish within 10s"
        }
    }
}
