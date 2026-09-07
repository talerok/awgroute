import Foundation

/// Собрать конфиг backend'а для профиля и записать его на диск.
///
/// Выделено из `ConnectTunnel`, у которого было восемь зависимостей и две разные
/// работы внутри. Теперь сборку конфига можно проверять без шлюза вовсе.
public struct BuildTunnelConfig: Sendable {
    private let renderer: ConfigRendering
    private let validator: ConfigValidating?
    private let materialize: MaterializeProfile
    private let rules: RulesRepository
    private let paths: RuntimePaths
    private let secretGenerator: SecretGenerating

    public init(
        renderer: ConfigRendering,
        validator: ConfigValidating?,
        materialize: MaterializeProfile,
        rules: RulesRepository,
        paths: RuntimePaths,
        secretGenerator: SecretGenerating
    ) {
        self.renderer = renderer
        self.validator = validator
        self.materialize = materialize
        self.rules = rules
        self.paths = paths
        self.secretGenerator = secretGenerator
    }

    /// Готовый к запуску конфиг: содержимое и список system DNS.
    ///
    /// Именно содержимое, а не путь: на диск его кладёт тот, кто запускает backend.
    /// Пока файл принадлежал GUI, между «записал» и «backend открыл» существовало
    /// окно, в котором GUI успевал его удалить.
    public struct Prepared: Equatable, Sendable {
        public let config: Data
        public let dnsServers: [String]
    }

    public func callAsFunction(profile: Profile) async throws -> Prepared {
        let config = try materialize(profile)

        let userRules = rules.load()
        if case .invalid(let detail) = renderer.validate(rules: userRules) {
            // Битый rules.json раньше глотался через `try?`: пользователь подключался
            // вообще без своих правил и никак об этом не узнавал.
            throw TunnelError.invalidRules(detail)
        }

        let options = RenderOptions(
            remoteDNSServer: Self.remoteDNS(from: config.interface.dns),
            cacheFilePath: paths.backendCache,
            clashAPISecret: secretGenerator.newSecret()
        )

        let data: Data
        do {
            data = try renderer.render(config: config, rules: userRules, options: options)
        } catch {
            throw TunnelError.configRejected("\(error)")
        }
        // Проверяем ДО старта: иначе ошибка схемы всплывёт FATAL-ом в логе через
        // десять секунд, а UI всё это время будет показывать «Running».
        if let validator, let problem = await validator.validate(config: data) {
            throw TunnelError.configRejected(problem)
        }

        return Prepared(config: data,
                        dnsServers: Self.systemDNSList(profileDNS: config.interface.dns))
    }

    // MARK: - Политики выбора DNS

    /// Удалённый DNS для туннеля: первый адрес вне CGNAT.
    ///
    /// CGNAT-адреса (100.64.0.0/10) — внутренние резолверы VPN-сервера, они часто
    /// тормозят на части доменов. RFC1918 не отсекаем: через туннель такой DNS рабочий.
    public static func remoteDNS(from profileDNS: [String]) -> String {
        profileDNS.first(where: isNonCGNATIPv4) ?? "1.1.1.1"
    }

    public static func isNonCGNATIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return !(parts[0] == 100 && (64...127).contains(parts[1]))
    }

    /// Системный DNS-override: достижимые резолверы первыми.
    ///
    /// Внутренний VPN-адрес, стоящий первым, недостижим до поднятия туннеля —
    /// каждый резолв на старте упирался в его таймаут.
    public static func systemDNSList(profileDNS: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t).inserted else { return }
            result.append(t)
        }
        for dns in profileDNS where isNonCGNATIPv4(dns) { add(dns) }
        for fallback in ["1.1.1.1", "8.8.8.8"] { add(fallback) }
        for dns in profileDNS where !isNonCGNATIPv4(dns) { add(dns) }
        return result
    }
}
