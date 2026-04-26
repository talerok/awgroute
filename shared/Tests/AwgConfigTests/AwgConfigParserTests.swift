import XCTest
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
        XCTAssertEqual(i.i1, "<b 0xf6><c><t><r 10>")
        XCTAssertEqual(i.i2, "<b 0x00 0x01><c><r 30>")
        XCTAssertNil(i.i3)
        XCTAssertNil(i.i4)
        XCTAssertNil(i.i5)
        XCTAssertEqual(cfg.peers[0].presharedKey, "ZmFrZXByZXNoYXJlZGtleWZvcnRlc3RpbmcxMjM0NTY3ODkwYWE=")
        XCTAssertEqual(cfg.peers[0].endpointHost, "vpn.example.com")
        XCTAssertEqual(cfg.peers[0].allowedIPs, ["0.0.0.0/0", "::/0"])
        XCTAssertEqual(cfg.peers[0].persistentKeepalive, 25)
    }

    func testNoPSK() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("no_psk"))
        XCTAssertNil(cfg.peers[0].presharedKey)
        XCTAssertEqual(cfg.peers[0].persistentKeepalive, 25)
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
        XCTAssertEqual(cfg.peers[1].persistentKeepalive, 30)
    }

    func testUnknownKeysAreWarnings() throws {
        let cfg = try AwgConfigParser.parse(try loadFixture("with_unknown_keys"))
        XCTAssertFalse(cfg.warnings.isEmpty)
        XCTAssertTrue(cfg.warnings.contains { $0.contains("J1") })
        XCTAssertTrue(cfg.warnings.contains { $0.contains("Itime") })
        XCTAssertTrue(cfg.warnings.contains { $0.contains("SomeRandomKey") })
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
}
