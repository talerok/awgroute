import Foundation
import AwgDomain

/// Генератор JSON для amnezia-box.
///
/// Производит:
/// - `endpointJSON(...)` — только секция `endpoints[]` (один AWG endpoint).
/// - `fullConfigJSON(...)` — полный конфиг: log + dns + tun inbound + direct outbound +
///   AWG endpoint + route (sniff + hijack-dns + final) + experimental.clash_api.
///
/// Имена JSON-полей строго по `option/awg.go` ветки `awg-1.14.0` (см. DECISIONS.md).
public enum AwgJSONGenerator {

    public struct Options: Sendable {
        /// Тег endpoint в JSON. Используется в `route.final` и DNS detour.
        public var endpointTag: String = "vpn"
        /// Имя TUN-интерфейса (utun*).
        public var tunInterfaceName: String = "utun123"
        /// Внутренний IP TUN-интерфейса (не пересекается с обычным LAN).
        public var tunAddress: String = "172.19.0.1/30"
        /// MTU для TUN inbound. 1376 — то же значение, что выставляет нативный
        /// AmneziaVPN на macOS. Outer-пакет: 1376 + WG(48) + UDP/IP(28) = 1452,
        /// помещается в стандартный 1500-MTU Ethernet с запасом 48 байт под
        /// промежуточные туннели. Завышение до 1408 ломало Chromium-handshake
        /// на gVisor netstack (см. PR с этим фиксом).
        public var tunMTU: UInt32 = 1376
        /// Адрес Clash API.
        public var clashAPIListen: String = "127.0.0.1:9090"
        /// Токен для Clash API. Без него любой локальный процесс читает `/connections`
        /// — то есть адреса назначения всего туннелируемого трафика — и может менять
        /// роутинг через тот же контрольный API, которым пользуется приложение.
        /// nil — поле не генерится (обратная совместимость и отладка вручную).
        public var clashAPISecret: String? = nil
        /// Порядок: ipv4_only / prefer_ipv4 / etc.
        public var dnsStrategy: String = "ipv4_only"
        /// Локальный (системный) DNS — для bypass-доменов и default_domain_resolver.
        public var localDNSServer: String = "192.168.1.1"
        /// Удалённый DNS — для туннеля.
        public var remoteDNSServer: String = "1.1.1.1"
        /// Путь к `experimental.cache_file`. Кеширует скачанные remote rule-set'ы.
        ///
        /// Без него sing-box качает каждый rule-set заново при КАЖДОМ старте, и любой
        /// сетевой сбой валит туннель целиком: `RemoteRuleSet.StartContext` при
        /// отсутствии кеша и `initial_path` идёт в `fetch`, а его ошибка фатальна
        /// (`start service: initial rule-set: ...`). С кешем повторный старт
        /// поднимается вообще без сети.
        ///
        /// Путь задаёт вызывающий: backend работает под root, и файл должен лечь
        /// туда, где это безопасно. nil — секция не генерится.
        public var cacheFilePath: String? = nil
        /// Native TUN режим: AWG сам поднимает системный utun, sing-box-роутинг
        /// отключён. Простой full-tunnel, как нативный AmneziaVPN-клиент.
        /// Используй, если smart-mode (с rules) не работает.
        public var useNativeTunMode: Bool = false

        public init() {}
    }

    /// Возвращает JSON только endpoint-объекта (то, что лежит в `endpoints[]`).
    public static func endpointJSON(
        from config: AwgConfig,
        options: Options = Options()
    ) throws -> Data {
        let dict = endpointDict(from: config, options: options)
        return try serialize(dict)
    }

    /// Полный конфиг amnezia-box. `userRoute` — пользовательский JSON правил из этапа 4.
    /// Если `userRoute == nil`, route собирается минимально (sniff + hijack-dns + final → endpointTag).
    ///
    /// Если `options.useNativeTunMode == true` — генерится минимальный конфиг, где
    /// AWG сам управляет системным TUN (как в нативном AmneziaVPN). В этом режиме
    /// sing-box-роутинг и `userRoute` НЕ применяются: full-tunnel.
    public static func fullConfigJSON(
        from config: AwgConfig,
        options: Options = Options(),
        userRoute: [String: Any]? = nil,
        userDNS: [String: Any]? = nil
    ) throws -> Data {
        if options.useNativeTunMode {
            return try nativeTunConfigJSON(from: config, options: options)
        }
        let endpoint = endpointDict(from: config, options: options)

        // userDNS — опциональная секция `dns` из пользовательского rules.json
        // (Variant B). Поля, которые пользователь не указал, добираются из
        // дефолтного DNS-словаря, чтобы не потерять `local` сервер и др.
        //
        // Выбор `options.remoteDNSServer` — ответственность вызывающего слоя
        // (ConnectionCoordinator), там умная логика пропуска CGNAT-DNS. Генератор
        // не лезет в config.interface.dns, чтобы не дублировать/перебивать её.
        var dns: [String: Any] = userDNS ?? [:]
        let defaults = defaultDNSDict(options: options)
        if dns["servers"]  == nil { dns["servers"]  = defaults["servers"] }
        if dns["final"]    == nil { dns["final"]    = defaults["final"] }
        if dns["rules"]    == nil { dns["rules"]    = defaults["rules"] }
        if dns["strategy"] == nil { dns["strategy"] = defaults["strategy"] }

        // TUN MTU должен быть НЕ БОЛЬШЕ AWG MTU, иначе пакеты от TUN не влезают
        // в AWG payload (WG header + AWG padding S1..S4). Если в профиле задан
        // MTU — синхронизируем, иначе используем дефолт TUN.
        let effectiveTunMTU = config.interface.mtu ?? options.tunMTU
        let inbounds: [[String: Any]] = [[
            "type": "tun",
            "tag": "tun-in",
            "interface_name": options.tunInterfaceName,
            "address": [options.tunAddress],
            "mtu": effectiveTunMTU,
            "auto_route": true,
            "strict_route": false,
            // gvisor netstack — стабильнее на macOS с AWG, чем "system"
            // (с system наблюдалась деградация трафика через 15-20 сек после handshake)
            "stack": "gvisor"
        ]]

        // `direct` outbound нужен, чтобы пользовательские правила могли писать
        // `"outbound": "direct"` и `"final": "direct"` (для bypass-роутинга).
        // В прошлой итерации мы его убрали из-за ошибки "detour to an empty
        // direct outbound makes no sense" — но та ошибка была из DNS server'а
        // c `detour: "direct"`. Сейчас наш local DNS использует тип "local" без
        // detour, и проблема ушла.
        let outbounds: [[String: Any]] = [
            ["type": "direct", "tag": "direct"]
        ]

        let route = mergedRoute(userRoute: userRoute, options: options)

        let root: [String: Any] = [
            // info — повседневный режим. Видны старт/стоп, handshake, route ошибки.
            // Для глубокой отладки временно меняй на "debug" (на активном трафике
            // лог растёт ~500 КБ/мин — ротация срабатывает каждые 10-20 мин).
            "log": ["level": "info", "timestamp": true],
            "dns": dns,
            "inbounds": inbounds,
            "outbounds": outbounds,
            "endpoints": [endpoint],
            "route": route,
            "experimental": experimentalDict(options: options)
        ]
        return try serialize(root)
    }

    static func experimentalDict(options: Options) -> [String: Any] {
        var clash: [String: Any] = ["external_controller": options.clashAPIListen]
        if let secret = options.clashAPISecret, !secret.isEmpty {
            clash["secret"] = secret
        }
        var experimental: [String: Any] = ["clash_api": clash]
        if let path = options.cacheFilePath {
            experimental["cache_file"] = ["enabled": true, "path": path]
        }
        return experimental
    }

    // MARK: - Native TUN mode

    /// Минимальный конфиг: только endpoint c `useIntegratedTun: true`.
    /// AWG поднимает свой системный TUN, делает auto_route, всё работает
    /// как в нативном AmneziaVPN-клиенте. Без sing-box-route и DNS-перехвата.
    static func nativeTunConfigJSON(from config: AwgConfig, options: Options) throws -> Data {
        var endpoint = endpointDict(from: config, options: options)
        endpoint["useIntegratedTun"] = true   // override
        let root: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "endpoints": [endpoint],
            "experimental": experimentalDict(options: options)
        ]
        return try serialize(root)
    }

    // MARK: - building blocks

    static func endpointDict(from config: AwgConfig, options: Options) -> [String: Any] {
        let iface = config.interface
        var endpoint: [String: Any] = [
            "type": "awg",
            "tag": options.endpointTag,
            "private_key": iface.privateKey,
            "address": iface.address,
            "useIntegratedTun": false
        ]
        if let v = iface.mtu        { endpoint["mtu"] = v }
        if let v = iface.listenPort { endpoint["listen_port"] = v }
        if let v = iface.jc         { endpoint["jc"] = v }
        if let v = iface.jmin       { endpoint["jmin"] = v }
        if let v = iface.jmax       { endpoint["jmax"] = v }
        if let v = iface.s1         { endpoint["s1"] = v }
        if let v = iface.s2         { endpoint["s2"] = v }
        if let v = iface.s3         { endpoint["s3"] = v }
        if let v = iface.s4         { endpoint["s4"] = v }
        if let v = iface.h1         { endpoint["h1"] = v }
        if let v = iface.h2         { endpoint["h2"] = v }
        if let v = iface.h3         { endpoint["h3"] = v }
        if let v = iface.h4         { endpoint["h4"] = v }
        if let v = iface.i1         { endpoint["i1"] = v }
        if let v = iface.i2         { endpoint["i2"] = v }
        if let v = iface.i3         { endpoint["i3"] = v }
        if let v = iface.i4         { endpoint["i4"] = v }
        if let v = iface.i5         { endpoint["i5"] = v }
        // ── AmneziaWG 3.x ──
        // header_protection_key backend ждёт в base64 (в hex переводит сам при
        // сборке UAPI). Тайминги — строкой "N" или "min-max".
        if let v = iface.headerProtectionKey    { endpoint["header_protection_key"] = v }
        if let v = iface.contentPaddingAddition { endpoint["content_padding_addition"] = v.description }
        if let v = iface.rekeyAfterTime         { endpoint["rekey_after_time"] = v.description }
        if let v = iface.rekeyTimeout           { endpoint["rekey_timeout"] = v.description }
        if let v = iface.rejectAfterTime        { endpoint["reject_after_time"] = v.description }
        if let v = iface.keepaliveTimeout       { endpoint["keepalive_timeout"] = v.description }
        if let v = iface.maxHandshakeAttempts   { endpoint["max_handshake_attempts"] = v.description }

        endpoint["peers"] = config.peers.map { peer -> [String: Any] in
            var p: [String: Any] = [
                "address": peer.endpointHost,
                "port": peer.endpointPort,
                "public_key": peer.publicKey,
                "allowed_ips": peer.allowedIPs
            ]
            if let psk = peer.presharedKey { p["preshared_key"] = psk }
            // Строкой: backend (AwgKeepalive) принимает и число, и "min-max".
            if let ka  = peer.persistentKeepalive { p["persistent_keepalive_interval"] = ka.description }
            return p
        }
        return endpoint
    }

    private static func defaultDNSDict(options: Options) -> [String: Any] {
        // `local` сервер (тип "local") использует системный resolver. У него НЕТ
        // detour — sing-box 1.12 ругается «detour to an empty direct outbound makes
        // no sense», т.к. direct в 1.12 — не явный outbound, а route-action.
        [
            "servers": [
                ["type": "udp",   "tag": "remote", "server": options.remoteDNSServer, "detour": options.endpointTag],
                ["type": "local", "tag": "local"]
            ],
            "rules": [],
            "final": "remote",
            "strategy": options.dnsStrategy
            // `independent_cache` — deprecated в sing-box 1.14, убрано
        ]
    }

    /// Применяет правила пользователя:
    /// - `final == "vpn"` и любые `outbound == "vpn"` (зарезервированное имя) →
    ///   подменяем на `options.endpointTag`
    /// - гарантируем sniff и hijack-dns в начале правил
    /// - проставляем `default_domain_resolver` если пользователь не указал
    static func mergedRoute(userRoute: [String: Any]?, options: Options) -> [String: Any] {
        var route: [String: Any] = userRoute ?? [:]
        // rules.json — это секция `route` ПЛЮС опциональная `dns` (Variant B).
        // `dns` разбирается отдельно в fullConfigJSON; если оставить её здесь, она
        // уедет внутрь route и sing-box откажется грузить конфиг целиком:
        //   FATAL decode config: route.dns: json: unknown field "dns"
        for key in Self.nonRouteUserKeys { route.removeValue(forKey: key) }

        var rules = (route["rules"] as? [[String: Any]]) ?? []
        let hasSniff = rules.contains { ($0["action"] as? String) == "sniff" }
        let hasHijack = rules.contains {
            ($0["action"] as? String) == "hijack-dns" && (($0["protocol"] as? String) == "dns")
        }
        var prefix: [[String: Any]] = []
        if !hasSniff  { prefix.append(["action": "sniff"]) }
        if !hasHijack { prefix.append(["protocol": "dns", "action": "hijack-dns"]) }
        rules = prefix + rules

        // Подмена "vpn" → endpointTag в outbound каждого правила. По умолчанию
        // endpointTag и есть "vpn", замена no-op — но если пользователь сменит тег
        // через Options, правила не сломаются (см. test_user_outbound_vpn_replaced).
        if options.endpointTag != "vpn" {
            rules = rules.map { rule -> [String: Any] in
                var r = rule
                if (r["outbound"] as? String) == "vpn" { r["outbound"] = options.endpointTag }
                return r
            }
        }
        route["rules"] = rules

        // final: подмена зарезервированного "vpn"
        if let f = route["final"] as? String {
            if f == "vpn" { route["final"] = options.endpointTag }
        } else {
            route["final"] = options.endpointTag
        }

        if route["default_domain_resolver"] == nil {
            route["default_domain_resolver"] = ["server": "local"]
        }
        if route["auto_detect_interface"] == nil {
            route["auto_detect_interface"] = true
        }
        return route
    }

    /// Ключи верхнего уровня rules.json, которые НЕ являются частью секции `route`.
    /// Обрабатываются отдельно и должны быть вырезаны перед сборкой route.
    static let nonRouteUserKeys: Set<String> = ["dns"]

    /// Достаёт из пользовательского rules.json секцию `dns` (Variant B), если она есть.
    public static func userDNSSection(from userRules: [String: Any]?) -> [String: Any]? {
        userRules?["dns"] as? [String: Any]
    }

    private static func serialize(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
