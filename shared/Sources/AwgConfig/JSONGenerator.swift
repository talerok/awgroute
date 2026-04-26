import Foundation

/// Генератор JSON для amnezia-box.
///
/// Производит:
/// - `endpointJSON(...)` — только секция `endpoints[]` (один AWG endpoint).
/// - `fullConfigJSON(...)` — полный конфиг: log + dns + tun inbound + direct outbound +
///   AWG endpoint + route (sniff + hijack-dns + final) + experimental.clash_api.
///
/// Имена JSON-полей строго по `option/awg.go` (см. DECISIONS.md).
public enum AwgJSONGenerator {

    public struct Options: Sendable {
        /// Тег endpoint в JSON. Используется в `route.final` и DNS detour.
        public var endpointTag: String = "vpn"
        /// Имя TUN-интерфейса (utun*).
        public var tunInterfaceName: String = "utun123"
        /// Внутренний IP TUN-интерфейса (не пересекается с обычным LAN).
        public var tunAddress: String = "172.19.0.1/30"
        /// MTU для TUN inbound (обычно 1408).
        public var tunMTU: UInt32 = 1408
        /// Адрес Clash API.
        public var clashAPIListen: String = "127.0.0.1:9090"
        /// Порядок: ipv4_only / prefer_ipv4 / etc.
        public var dnsStrategy: String = "ipv4_only"
        /// Локальный (системный) DNS — для bypass-доменов и default_domain_resolver.
        public var localDNSServer: String = "192.168.1.1"
        /// Удалённый DNS — для туннеля.
        public var remoteDNSServer: String = "1.1.1.1"
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
            "experimental": [
                "clash_api": [
                    "external_controller": options.clashAPIListen
                ]
            ]
        ]
        return try serialize(root)
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
            "experimental": [
                "clash_api": [
                    "external_controller": options.clashAPIListen
                ]
            ]
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

        endpoint["peers"] = config.peers.map { peer -> [String: Any] in
            var p: [String: Any] = [
                "address": peer.endpointHost,
                "port": peer.endpointPort,
                "public_key": peer.publicKey,
                "allowed_ips": peer.allowedIPs
            ]
            if let psk = peer.presharedKey { p["preshared_key"] = psk }
            if let ka  = peer.persistentKeepalive { p["persistent_keepalive_interval"] = ka }
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

    private static func serialize(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
