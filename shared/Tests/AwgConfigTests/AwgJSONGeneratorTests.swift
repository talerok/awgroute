import XCTest
import AwgDomain
@testable import AwgConfig

final class AwgJSONGeneratorTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "conf", subdirectory: "Fixtures")
        return try String(contentsOf: url!, encoding: .utf8)
    }

    private func parseToDict(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    func testEndpointFieldsMinimal() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("minimal"))
        let json = try AwgJSONGenerator.endpointJSON(from: cfg)
        let d = try parseToDict(json)

        XCTAssertEqual(d["type"] as? String, "awg")
        XCTAssertEqual(d["tag"] as? String, "vpn")
        XCTAssertEqual(d["private_key"] as? String, cfg.interface.privateKey)
        XCTAssertEqual(d["address"] as? [String], ["10.8.0.2/24"])
        XCTAssertEqual(d["useIntegratedTun"] as? Bool, false)

        // Optional поля отсутствуют, если нет в .conf
        XCTAssertNil(d["mtu"])
        XCTAssertNil(d["jc"])
        XCTAssertNil(d["i1"])

        let peers = d["peers"] as! [[String: Any]]
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers[0]["address"] as? String, "198.51.100.10")
        XCTAssertEqual(peers[0]["port"] as? Int, 51820)
        XCTAssertEqual(peers[0]["allowed_ips"] as? [String], ["0.0.0.0/0"])
        XCTAssertNil(peers[0]["preshared_key"])
    }

    func testEndpointFieldsFull() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("full_awg"))
        let json = try AwgJSONGenerator.endpointJSON(from: cfg)
        let d = try parseToDict(json)

        XCTAssertEqual(d["mtu"] as? Int, 1280)
        XCTAssertEqual(d["listen_port"] as? Int, 51820)
        XCTAssertEqual(d["jc"] as? Int, 4)
        XCTAssertEqual(d["jmin"] as? Int, 40)
        XCTAssertEqual(d["jmax"] as? Int, 70)
        XCTAssertEqual(d["s1"] as? Int, 50)
        XCTAssertEqual(d["s2"] as? Int, 100)
        // s3 / s4 == 0 — см. testS3IsNotZeroIsKept
        XCTAssertEqual(d["h1"] as? String, "1")
        XCTAssertEqual(d["i1"] as? String, "<b 0xf6><t><r 10>")
        XCTAssertEqual(d["i2"] as? String, "<b 0x00 0x01><r 30>")
        // Пустые I3-I5 → не в JSON
        XCTAssertNil(d["i3"])

        let peers = d["peers"] as! [[String: Any]]
        XCTAssertEqual(peers[0]["preshared_key"] as? String, "ZmFrZXByZXNoYXJlZGtleWZvcnRlc3RpbmcxMjM0NTY3ODkwYWE=")
        // Строкой: backend (AwgKeepalive) принимает и число, и "min-max".
        XCTAssertEqual(peers[0]["persistent_keepalive_interval"] as? String, "25")
        XCTAssertEqual(peers[0]["allowed_ips"] as? [String], ["0.0.0.0/0", "::/0"])
    }

    func testS3IsNotZeroIsKept() throws {
        // Поведение: 0 не должно фильтроваться в Models — но в JSON попадает как есть.
        // Парсер отличает "S3 = 0" → s3=0, генератор НЕ отбрасывает 0.
        // Проверяем явно: даже если в .conf S3=0, в JSON оно может отсутствовать.
        // Решение: пусть в JSON попадает значение как есть (включая 0) — это валидно для amnezia-box.
        // Тест документирует текущее поведение.
        let cfg = try AwgConfigParser.parse(try loadFixture("full_awg"))
        let json = try AwgJSONGenerator.endpointJSON(from: cfg)
        let d = try parseToDict(json)
        // s3, s4 == 0 в .conf — попадают в Int 0 в Swift модели,
        // но `endpointDict` использует `if let` для всех полей. Поскольку s3 = Int? = .some(0),
        // оно ДОЛЖНО попасть в JSON как 0. Проверим:
        // (Если решим иначе — этот тест придётся обновить вместе с моделью.)
        XCTAssertEqual(d["s3"] as? Int, 0)
        XCTAssertEqual(d["s4"] as? Int, 0)
    }

    func testFullConfigRouteDefaults() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("minimal"))
        let json = try AwgJSONGenerator.fullConfigJSON(from: cfg)
        let d = try parseToDict(json)

        let route = d["route"] as! [String: Any]
        let rules = route["rules"] as! [[String: Any]]
        XCTAssertEqual(rules.first?["action"] as? String, "sniff")
        XCTAssertEqual(rules[1]["protocol"] as? String, "dns")
        XCTAssertEqual(rules[1]["action"] as? String, "hijack-dns")
        XCTAssertEqual(route["final"] as? String, "vpn")
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
        let dr = route["default_domain_resolver"] as? [String: Any]
        XCTAssertEqual(dr?["server"] as? String, "local")

        let endpoints = d["endpoints"] as! [[String: Any]]
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoints[0]["tag"] as? String, "vpn")

        let inbounds = d["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds[0]["type"] as? String, "tun")
    }

    func testFullConfigRouteUserMergesSniff() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("minimal"))
        // Пользователь забыл sniff/hijack — генератор обязан подставить
        let userRoute: [String: Any] = [
            "rules": [
                ["domain_suffix": [".ru"], "outbound": "direct"]
            ],
            "final": "vpn"
        ]
        let json = try AwgJSONGenerator.fullConfigJSON(from: cfg, userRoute: userRoute)
        let d = try parseToDict(json)
        let rules = (d["route"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[0]["action"] as? String, "sniff")
        XCTAssertEqual(rules[1]["action"] as? String, "hijack-dns")
        XCTAssertEqual(rules[2]["domain_suffix"] as? [String], [".ru"])
    }

    func testFinalReservedVpnReplaced() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("minimal"))
        var opts = AwgJSONGenerator.Options()
        opts.endpointTag = "my-server"
        let userRoute: [String: Any] = ["final": "vpn"]
        let json = try AwgJSONGenerator.fullConfigJSON(from: cfg, options: opts, userRoute: userRoute)
        let d = try parseToDict(json)
        let route = d["route"] as! [String: Any]
        XCTAssertEqual(route["final"] as? String, "my-server")
    }

    func testUserOutboundVpnReplacedWhenEndpointTagChanged() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("minimal"))
        var opts = AwgJSONGenerator.Options()
        opts.endpointTag = "my-server"
        let userRoute: [String: Any] = [
            "rules": [
                ["domain_suffix": [".com"], "outbound": "vpn"],
                ["ip_is_private": true, "outbound": "direct"]
            ],
            "final": "vpn"
        ]
        let json = try AwgJSONGenerator.fullConfigJSON(from: cfg, options: opts, userRoute: userRoute)
        let d = try parseToDict(json)
        let rules = (d["route"] as! [String: Any])["rules"] as! [[String: Any]]
        // Префиксы sniff + hijack-dns + 2 пользовательских
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(rules[2]["outbound"] as? String, "my-server")
        XCTAssertEqual(rules[3]["outbound"] as? String, "direct")
    }

    func testUserDNSOverridesDefaults() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("minimal"))
        let userDNS: [String: Any] = [
            "servers": [
                ["type": "udp", "tag": "remote", "server": "9.9.9.9", "detour": "vpn"],
                ["type": "local", "tag": "local"]
            ],
            "final": "remote"
        ]
        let json = try AwgJSONGenerator.fullConfigJSON(from: cfg, userRoute: nil, userDNS: userDNS)
        let d = try parseToDict(json)
        let dns = d["dns"] as! [String: Any]
        let servers = dns["servers"] as! [[String: Any]]
        XCTAssertEqual(servers.first?["server"] as? String, "9.9.9.9")
        // strategy не задана пользователем — взято из дефолтов
        XCTAssertEqual(dns["strategy"] as? String, "ipv4_only")
    }

    func testWarningsExcludedFromCodable() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("with_unknown_keys"))
        XCTAssertFalse(cfg.warnings.isEmpty)
        let data = try JSONEncoder().encode(cfg)
        // warnings не должны попасть в JSON-сериализацию профиля
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(dict["warnings"], "warnings — runtime-only поле, не должно сериализоваться")
    }

    func testEqualityIgnoresWarnings() throws {
        let raw = try loadFixture("minimal")
        var a = try AwgConfigParser.parse(raw)
        var b = try AwgConfigParser.parse(raw)
        a.warnings = ["foo"]
        b.warnings = []
        XCTAssertEqual(a, b, "warnings не учитываются в Equatable")
    }

    func testTunMTUDefaultsTo1376WhenProfileHasNone() throws {
        // minimal не задаёт MTU → должен использоваться дефолт options.tunMTU = 1376
        // (то же значение, что и нативный AmneziaVPN). 1408 раньше ломал
        // Chromium-handshake через gVisor netstack.
        let cfg = try AwgConfigParser.parse(try loadFixture("minimal"))
        let json = try AwgJSONGenerator.fullConfigJSON(from: cfg)
        let d = try parseToDict(json)
        let inbounds = d["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds[0]["mtu"] as? Int, 1376)
    }

    func testTunMTUFollowsProfileMTU() throws {
        // full_awg задаёт MTU=1280 → TUN тоже 1280 (не больше AWG MTU).
        let cfg = try AwgConfigParser.parse(try loadFixture("full_awg"))
        let json = try AwgJSONGenerator.fullConfigJSON(from: cfg)
        let d = try parseToDict(json)
        let inbounds = d["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds[0]["mtu"] as? Int, 1280)
    }

    func testRemoteDNSUsesOptionsValue() throws {
        // Выбор DNS — ответственность вызывающего слоя (ConnectionCoordinator),
        // там умная логика пропуска CGNAT-DNS (внутренних VPN-резолверов,
        // которые часто тормозят на части доменов). Генератор просто
        // берёт options.remoteDNSServer как есть, не лезет в config.interface.dns.
        // Этот тест документирует это разделение ответственности.
        let cfg = try AwgConfigParser.parse(try loadFixture("full_awg")) // имеет DNS=1.1.1.1,1.0.0.1
        var opts = AwgJSONGenerator.Options()
        opts.remoteDNSServer = "8.8.8.8" // не дублирует ничего из cfg.interface.dns
        let json = try AwgJSONGenerator.fullConfigJSON(from: cfg, options: opts)
        let d = try parseToDict(json)
        let dns = d["dns"] as! [String: Any]
        let servers = dns["servers"] as! [[String: Any]]
        let remote = servers.first { ($0["tag"] as? String) == "remote" }
        XCTAssertEqual(remote?["server"] as? String, "8.8.8.8")
    }

    func testIPv6PeerEndpoint() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("ipv6_endpoint"))
        let json = try AwgJSONGenerator.endpointJSON(from: cfg)
        let d = try parseToDict(json)
        let peer = (d["peers"] as! [[String: Any]])[0]
        XCTAssertEqual(peer["address"] as? String, "2001:db8::1")
        XCTAssertEqual(peer["port"] as? Int, 51820)
    }

    // MARK: - Variant B: секция dns внутри rules.json

    func testUserDNSSectionIsStrippedFromRoute() throws {
        // Регрессия: rules.json = route + опциональная dns. Если dns утекала в route,
        // sing-box отвергал ВЕСЬ конфиг: `route.dns: json: unknown field "dns"`.
        let userRules: [String: Any] = [
            "rules": [["domain_suffix": ["example.com"], "outbound": "direct"]],
            "final": "vpn",
            "dns": ["final": "remote"]
        ]
        let cfg = try AwgConfigParser.parse(Self.minimalConf)
        let data = try AwgJSONGenerator.fullConfigJSON(
            from: cfg,
            userRoute: userRules,
            userDNS: AwgJSONGenerator.userDNSSection(from: userRules)
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertNil(route["dns"], "секция dns не должна попадать в route")
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        XCTAssertEqual(dns["final"] as? String, "remote", "dns из rules.json должна применяться")
        XCTAssertNotNil(dns["servers"], "недостающие поля добираются из дефолтов")
    }

    func testUserDNSSectionExtraction() {
        XCTAssertNil(AwgJSONGenerator.userDNSSection(from: nil))
        XCTAssertNil(AwgJSONGenerator.userDNSSection(from: ["final": "vpn"]))
        XCTAssertEqual(
            AwgJSONGenerator.userDNSSection(from: ["dns": ["final": "remote"]])?["final"] as? String,
            "remote"
        )
    }

    private static let minimalConf = """
    [Interface]
    Address = 10.8.0.2/24
    PrivateKey = aGVsbG93b3JsZGZha2Vwcml2YXRla2V5MTIzNDU2Nzg5MA==

    [Peer]
    PublicKey = ZmFrZXBlZXJwdWJsaWNrZXlmb3J0ZXN0aW5nMTIzNDU2Nzg5MA==
    Endpoint = 198.51.100.10:51820
    AllowedIPs = 0.0.0.0/0
    """

    // MARK: - AmneziaWG 3.x

    func testAwg3FieldsInEndpointJSON() throws {
        let cfg = try AwgConfigParser.parse("""
        [Interface]
        Address = 10.0.0.1/32
        PrivateKey = abc
        S1 = 643
        S4 = 12
        HeaderProtectionKey = ZmFrZWhlYWRlcnByb3RlY3Rpb25rZXktZm9yLXRlc3Rz
        RekeyAfterTime = 100-120
        ContentPaddingAddition = 10-100
        MaxHandshakeAttempts = 15-20

        [Peer]
        PublicKey = def
        Endpoint = 1.2.3.4:51820
        AllowedIPs = 0.0.0.0/0
        PersistentKeepalive = 25-35
        """)
        let d = AwgJSONGenerator.endpointDict(from: cfg, options: .init())
        // base64 как в .conf — в hex переводит сам backend при сборке UAPI.
        XCTAssertEqual(d["header_protection_key"] as? String, "ZmFrZWhlYWRlcnByb3RlY3Rpb25rZXktZm9yLXRlc3Rz")
        XCTAssertEqual(d["rekey_after_time"] as? String, "100-120")
        XCTAssertEqual(d["content_padding_addition"] as? String, "10-100")
        XCTAssertEqual(d["max_handshake_attempts"] as? String, "15-20")
        // Не заданные в .conf — не попадают в JSON.
        XCTAssertNil(d["rekey_timeout"])
        XCTAssertNil(d["reject_after_time"])
        XCTAssertNil(d["keepalive_timeout"])
        let peers = try XCTUnwrap(d["peers"] as? [[String: Any]])
        XCTAssertEqual(peers[0]["persistent_keepalive_interval"] as? String, "25-35")
    }
}
