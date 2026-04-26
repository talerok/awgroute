import XCTest
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
        XCTAssertEqual(d["i1"] as? String, "<b 0xf6><c><t><r 10>")
        XCTAssertEqual(d["i2"] as? String, "<b 0x00 0x01><c><r 30>")
        // Пустые I3-I5 → не в JSON
        XCTAssertNil(d["i3"])

        let peers = d["peers"] as! [[String: Any]]
        XCTAssertEqual(peers[0]["preshared_key"] as? String, "ZmFrZXByZXNoYXJlZGtleWZvcnRlc3RpbmcxMjM0NTY3ODkwYWE=")
        XCTAssertEqual(peers[0]["persistent_keepalive_interval"] as? Int, 25)
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

    func testIPv6PeerEndpoint() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("ipv6_endpoint"))
        let json = try AwgJSONGenerator.endpointJSON(from: cfg)
        let d = try parseToDict(json)
        let peer = (d["peers"] as! [[String: Any]])[0]
        XCTAssertEqual(peer["address"] as? String, "2001:db8::1")
        XCTAssertEqual(peer["port"] as? Int, 51820)
    }
}
