import XCTest
import AwgDomain
@testable import AwgConfig

final class AwgConfigParserTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "conf", subdirectory: "Fixtures")
        XCTAssertNotNil(url, "Fixture \(name).conf not found in bundle")
        return try String(contentsOf: url!, encoding: .utf8)
    }

    func testMinimal() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("minimal"))
        XCTAssertEqual(cfg.interface.address, ["10.8.0.2/24"])
        XCTAssertEqual(cfg.interface.privateKey, "aGVsbG93b3JsZGZha2Vwcml2YXRla2V5MTIzNDU2Nzg5MA==")
        XCTAssertEqual(cfg.interface.dns, [])
        XCTAssertNil(cfg.interface.mtu)
        XCTAssertNil(cfg.interface.jc)
        XCTAssertEqual(cfg.peers.count, 1)
        XCTAssertEqual(cfg.peers[0].endpointHost, "198.51.100.10")
        XCTAssertEqual(cfg.peers[0].endpointPort, 51820)
        XCTAssertEqual(cfg.peers[0].allowedIPs, ["0.0.0.0/0"])
        XCTAssertNil(cfg.peers[0].presharedKey)
    }

    func testFullAwg() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("full_awg"))
        let i = cfg.interface
        XCTAssertEqual(i.dns, ["1.1.1.1", "1.0.0.1"])
        XCTAssertEqual(i.mtu, 1280)
        XCTAssertEqual(i.listenPort, 51820)
        XCTAssertEqual(i.jc, 4)
        XCTAssertEqual(i.jmin, 40)
        XCTAssertEqual(i.jmax, 70)
        XCTAssertEqual(i.s1, 50)
        XCTAssertEqual(i.s2, 100)
        // I3-I5 пустые → nil
        XCTAssertEqual(i.i1, "<b 0xf6><t><r 10>")
        XCTAssertEqual(i.i2, "<b 0x00 0x01><r 30>")
        XCTAssertNil(i.i3)
        XCTAssertNil(i.i4)
        XCTAssertNil(i.i5)
        XCTAssertEqual(cfg.peers[0].presharedKey, "ZmFrZXByZXNoYXJlZGtleWZvcnRlc3RpbmcxMjM0NTY3ODkwYWE=")
        XCTAssertEqual(cfg.peers[0].endpointHost, "vpn.example.com")
        XCTAssertEqual(cfg.peers[0].allowedIPs, ["0.0.0.0/0", "::/0"])
        XCTAssertEqual(cfg.peers[0].persistentKeepalive, AwgRange(25))
    }

    func testNoPSK() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("no_psk"))
        XCTAssertNil(cfg.peers[0].presharedKey)
        XCTAssertEqual(cfg.peers[0].persistentKeepalive, AwgRange(25))
        XCTAssertEqual(cfg.interface.dns, ["9.9.9.9"])
    }

    func testIPv6Endpoint() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("ipv6_endpoint"))
        XCTAssertEqual(cfg.interface.address, ["10.0.0.7/32", "fd00::7/128"])
        XCTAssertEqual(cfg.peers[0].endpointHost, "2001:db8::1")
        XCTAssertEqual(cfg.peers[0].endpointPort, 51820)
    }

    func testMultiPeer() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("multi_peer"))
        XCTAssertEqual(cfg.peers.count, 2)
        XCTAssertEqual(cfg.peers[0].endpointHost, "peer1.example.com")
        XCTAssertEqual(cfg.peers[1].endpointHost, "peer2.example.com")
        XCTAssertEqual(cfg.peers[1].persistentKeepalive, AwgRange(30))
    }

    func testUnknownKeysAreWarnings() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("with_unknown_keys"))
        XCTAssertFalse(cfg.warnings.isEmpty)
        XCTAssertTrue(cfg.warnings.contains { $0.contains("J1") })
        XCTAssertTrue(cfg.warnings.contains { $0.contains("Itime") })
        XCTAssertTrue(cfg.warnings.contains { $0.contains("SomeRandomKey") })
    }

    func testAwg31RangesArePreservedVerbatim() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("awg31_ranges"))
        let i = cfg.interface
        // Диапазон НЕ схлопывается: рандомизация внутри интервала — смысл параметра.
        XCTAssertEqual(cfg.peers[0].persistentKeepalive, AwgRange("25-35"))
        XCTAssertEqual(cfg.peers[0].persistentKeepalive?.description, "25-35")
        XCTAssertEqual(i.rekeyAfterTime, AwgRange("100-120"))
        XCTAssertEqual(i.rekeyTimeout, AwgRange("3-8"))
        XCTAssertEqual(i.rejectAfterTime, AwgRange("150-180"))
        XCTAssertEqual(i.keepaliveTimeout, AwgRange("7-13"))
        XCTAssertEqual(i.maxHandshakeAttempts, AwgRange("15-20"))
        XCTAssertEqual(i.contentPaddingAddition, AwgRange("10-100"))
        XCTAssertNotNil(i.headerProtectionKey)
        XCTAssertEqual(i.jc, 4)
        XCTAssertEqual(i.s3, 1051)
        // Всё поддержано backend'ом — предупреждать больше не о чем.
        XCTAssertEqual(cfg.warnings, [], "неожиданные warnings: \(cfg.warnings)")
    }

    func testHeaderProtectionRequiresBigPaddings() throws {
        // backend откажется стартовать: "s4 must be at least 12 when
        // header_protection_key is set". Ловим на импорте.
        let raw = """
        [Interface]
        Address = 10.0.0.1/32
        PrivateKey = abc
        S1 = 643
        S4 = 8
        HeaderProtectionKey = ZmFrZQ==

        [Peer]
        PublicKey = def
        Endpoint = 1.2.3.4:51820
        AllowedIPs = 0.0.0.0/0
        """
        let cfg = try AwgConfigParser.parse(raw)
        XCTAssertTrue(cfg.warnings.contains { $0.contains("S4=8") && $0.contains("не меньше 12") },
                      "warnings: \(cfg.warnings)")
    }

    func testAwgRangeParsingAndCodable() throws {
        XCTAssertEqual(AwgRange("25")?.description, "25")
        XCTAssertEqual(AwgRange(" 25 - 35 ")?.description, "25-35")
        XCTAssertFalse(AwgRange("25")!.isRange)
        XCTAssertTrue(AwgRange("25-35")!.isRange)
        XCTAssertNil(AwgRange("35-25"), "верхняя граница ниже нижней")
        XCTAssertNil(AwgRange("1-2-3"))
        XCTAssertNil(AwgRange("abc"))

        // Профили, сохранённые до AWG 3.x, хранят скаляр ЧИСЛОМ — должны читаться.
        let fromNumber = try JSONDecoder().decode(AwgRange.self, from: Data("25".utf8))
        XCTAssertEqual(fromNumber, AwgRange(25))
        let fromString = try JSONDecoder().decode(AwgRange.self, from: Data("\"25-35\"".utf8))
        XCTAssertEqual(fromString, AwgRange("25-35"))
        // Пишем всегда строкой.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(AwgRange("25-35")!), as: UTF8.self), "\"25-35\"")
    }

    func testLegacyProfileWithNumericKeepaliveDecodes() throws {
        // Полный round-trip старого профиля с диска: persistentKeepalive числом.
        let legacy = """
        {"interface":{"address":["10.0.0.1/32"],"privateKey":"abc","dns":[]},
         "peers":[{"publicKey":"def","endpointHost":"1.2.3.4","endpointPort":51820,
                   "allowedIPs":["0.0.0.0/0"],"persistentKeepalive":25}]}
        """
        let cfg = try JSONDecoder().decode(AwgConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(cfg.peers[0].persistentKeepalive, AwgRange(25))
    }

    func testRangeCollapseIsDeterministic() throws {
        let text = try loadFixture("awg31_ranges")
        XCTAssertEqual(try AwgConfigParser.parse(text), try AwgConfigParser.parse(text))
    }

    func testMalformedNumberStillThrows() {
        let raw = """
        [Interface]
        Address = 10.0.0.1/32
        PrivateKey = abc
        MTU = 12-34-56

        [Peer]
        PublicKey = abc
        Endpoint = 1.2.3.4:51820
        AllowedIPs = 0.0.0.0/0
        """
        XCTAssertThrowsError(try AwgConfigParser.parse(raw)) { err in
            XCTAssertEqual(err as? AwgConfigError, .invalidNumber(key: "MTU", value: "12-34-56"))
        }
    }

    func testUnknownPeerKeyIsWarning() throws {
        let raw = """
        [Interface]
        Address = 10.0.0.1/32
        PrivateKey = abc

        [Peer]
        PublicKey = abc
        Endpoint = 1.2.3.4:51820
        AllowedIPs = 0.0.0.0/0
        SomePeerKey = value
        """
        let cfg = try AwgConfigParser.parse(raw)
        XCTAssertTrue(cfg.warnings.contains { $0.contains("Unknown [Peer] key: SomePeerKey") })
    }

    func testMissingInterface() {
        let raw = """
        [Peer]
        PublicKey = abc
        Endpoint = 1.2.3.4:51820
        AllowedIPs = 0.0.0.0/0
        """
        XCTAssertThrowsError(try AwgConfigParser.parse(raw)) { err in
            XCTAssertEqual(err as? AwgConfigError, .missingSection("Interface"))
        }
    }

    func testMissingPeer() {
        let raw = """
        [Interface]
        Address = 10.0.0.1/32
        PrivateKey = abc
        """
        XCTAssertThrowsError(try AwgConfigParser.parse(raw)) { err in
            XCTAssertEqual(err as? AwgConfigError, .missingSection("Peer"))
        }
    }

    func testEndpointParsing() throws {
        XCTAssertEqual(try AwgConfigParser.parseEndpoint("1.2.3.4:51820").0, "1.2.3.4")
        XCTAssertEqual(try AwgConfigParser.parseEndpoint("1.2.3.4:51820").1, 51820)
        XCTAssertEqual(try AwgConfigParser.parseEndpoint("vpn.example.com:443").0, "vpn.example.com")
        XCTAssertEqual(try AwgConfigParser.parseEndpoint("[::1]:51820").0, "::1")
        XCTAssertEqual(try AwgConfigParser.parseEndpoint("[2001:db8::1]:443").1, 443)
        XCTAssertThrowsError(try AwgConfigParser.parseEndpoint("noport"))
        XCTAssertThrowsError(try AwgConfigParser.parseEndpoint(":51820"))
    }

    func testCRLFLineNumbersAndParsing() throws {
        let raw = "[Interface]\r\nAddress = 10.0.0.1/32\r\nPrivateKey = abc\r\n\r\n[Peer]\r\nPublicKey = def\r\nEndpoint = 1.2.3.4:51820\r\nAllowedIPs = 0.0.0.0/0\r\n"
        let cfg = try AwgConfigParser.parse(raw)
        XCTAssertEqual(cfg.interface.privateKey, "abc", "\\r не должен попадать в значение")
        XCTAssertEqual(cfg.peers[0].endpointPort, 51820)
    }

    func testCRLFMalformedLineNumberIsCorrect() {
        let raw = "[Interface]\r\nAddress = 10.0.0.1/32\r\ngarbage-without-equals\r\n"
        XCTAssertThrowsError(try AwgConfigParser.parse(raw)) { err in
            // Строка 3 — раньше CRLF удваивал индекс и получалось 5.
            XCTAssertEqual(err as? AwgConfigError,
                           .malformedLine(line: "garbage-without-equals", lineNumber: 3))
        }
    }

    func testDuplicateInterfaceSectionMerges() throws {
        let raw = """
        [Interface]
        Address = 10.0.0.1/32

        [Peer]
        PublicKey = def
        Endpoint = 1.2.3.4:51820
        AllowedIPs = 0.0.0.0/0

        [Interface]
        PrivateKey = abc
        """
        // Раньше второй [Interface] затирал первый и парсер падал на missing Address.
        let cfg = try AwgConfigParser.parse(raw)
        XCTAssertEqual(cfg.interface.address, ["10.0.0.1/32"])
        XCTAssertEqual(cfg.interface.privateKey, "abc")
    }

    func testUnknownObfuscationTagWarns() throws {
        // <c> (счётчик пакетов) был в AWG 1.5, в amneziawg-go v3 его нет.
        // Backend отвергает такой профиль на старте: IPC error -22.
        let raw = """
        [Interface]
        Address = 10.0.0.1/32
        PrivateKey = abc
        I1 = <b 0xf6><c><t><r 10>

        [Peer]
        PublicKey = def
        Endpoint = 1.2.3.4:51820
        AllowedIPs = 0.0.0.0/0
        """
        let cfg = try AwgConfigParser.parse(raw)
        XCTAssertTrue(cfg.warnings.contains { $0.contains("I1") && $0.contains("<c>") },
                      "warnings: \(cfg.warnings)")
        // Валидные теги молчат.
        XCTAssertEqual(AwgConfigParser.unknownTagWarnings("<b 0xf6><t><r 10><rc 5><dz>", key: "I1"), [])
    }
}
