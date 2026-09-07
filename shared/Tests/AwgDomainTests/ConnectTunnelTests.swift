import XCTest
@testable import AwgDomain

final class ConnectTunnelTests: XCTestCase {

    private var gateway: FakeGateway!
    private var secrets: FakeSecrets!
    private var rules: FakeRules!
    private var renderer: FakeRenderer!
    private var validator: FakeValidator!

    override func setUp() {
        super.setUp()
        gateway = FakeGateway(); secrets = FakeSecrets()
        rules = FakeRules(); renderer = FakeRenderer(); validator = FakeValidator()
    }

    private func makeSUT() -> ConnectTunnel {
        ConnectTunnel(
            build: BuildTunnelConfig(
                renderer: renderer,
                validator: validator,
                materialize: MaterializeProfile(secrets: secrets),
                rules: rules,
                paths: StubPaths(),
                secretGenerator: StubSecretGen(value: "secret-abc")
            ),
            gateway: gateway
        )
    }

    func testWithoutActiveProfileFails() async {
        do { _ = try await makeSUT()(profile: nil); XCTFail("должно бросить") }
        catch { XCTAssertEqual(error as? TunnelError, .noActiveProfile) }
    }

    func testMissingPrivateKeyIsReportedNotSwallowed() async {
        let p = Sample.profile()   // секрета в хранилище нет
        do { _ = try await makeSUT()(profile: p); XCTFail("должно бросить") }
        catch {
            guard case .secretMissing(_, let what)? = error as? TunnelError else {
                return XCTFail("не тот тип: \(error)")
            }
            XCTAssertEqual(what, "Private key")
        }
    }

    func testMissingPresharedKeyIsReported() async {
        let id = UUID()
        secrets.privateKeys[id] = "pk"
        let p = Sample.profile(id, withPSK: true)
        do { _ = try await makeSUT()(profile: p); XCTFail("должно бросить") }
        catch {
            guard case .secretMissing(_, let what)? = error as? TunnelError else {
                return XCTFail("не тот тип: \(error)")
            }
            XCTAssertEqual(what, "Preshared key for peer 1")
        }
    }

    func testInvalidRulesAbortConnect() async {
        let id = UUID(); secrets.privateKeys[id] = "pk"
        renderer.validation = .invalid("unexpected token")
        do { _ = try await makeSUT()(profile: Sample.profile(id)); XCTFail("должно бросить") }
        catch { XCTAssertEqual(error as? TunnelError, .invalidRules("unexpected token")) }
        XCTAssertTrue(gateway.startCalls.isEmpty, "backend не должен стартовать с битыми правилами")
    }

    func testRejectedConfigNeverReachesGateway() async {
        let id = UUID(); secrets.privateKeys[id] = "pk"
        validator.problem = "route.dns: unknown field"
        do { _ = try await makeSUT()(profile: Sample.profile(id)); XCTFail("должно бросить") }
        catch { XCTAssertEqual(error as? TunnelError, .configRejected("route.dns: unknown field")) }
        XCTAssertTrue(gateway.startCalls.isEmpty)
    }

    func testHappyPathWritesConfigAndStarts() async throws {
        let id = UUID(); secrets.privateKeys[id] = "pk"
        let status = try await makeSUT()(profile: Sample.profile(id))
        XCTAssertEqual(status, .running(pid: 42))
        XCTAssertFalse(gateway.startCalls[0].0.isEmpty, "конфиг уезжает содержимым")
        XCTAssertEqual(gateway.startCalls.count, 1)
        XCTAssertEqual(renderer.lastOptions?.clashAPISecret, "secret-abc")
        XCTAssertEqual(renderer.lastOptions?.cacheFilePath, StubPaths().backendCache)
    }

    func testRestartModeUsesRestartNotStart() async throws {
        let id = UUID(); secrets.privateKeys[id] = "pk"
        _ = try await makeSUT()(profile: Sample.profile(id), mode: .restart)
        // Регрессия: reconnect через start() был no-op — backend уже в .running,
        // и start возвращался немедленно, а цикл ретраев считал это успехом.
        XCTAssertTrue(gateway.startCalls.isEmpty)
        XCTAssertEqual(gateway.restartCalls.count, 1)
    }
}

final class DNSPolicyTests: XCTestCase {

    func testRemoteDNSSkipsCGNAT() {
        XCTAssertEqual(BuildTunnelConfig.remoteDNS(from: ["100.64.0.1", "8.8.4.4"]), "8.8.4.4")
        XCTAssertEqual(BuildTunnelConfig.remoteDNS(from: ["100.127.255.255", "1.0.0.1"]), "1.0.0.1")
        XCTAssertEqual(BuildTunnelConfig.remoteDNS(from: ["100.64.0.1"]), "1.1.1.1", "фолбэк")
        // RFC1918 отсекать не надо: через туннель такой резолвер работает.
        XCTAssertEqual(BuildTunnelConfig.remoteDNS(from: ["10.8.0.1"]), "10.8.0.1")
        XCTAssertEqual(BuildTunnelConfig.remoteDNS(from: ["fd00::1"]), "1.1.1.1", "IPv6 не подходит")
    }

    func testSystemDNSPutsReachableServersFirst() {
        // Ключевое: 100.64.0.1 недостижим, пока туннель не поднят. Стоя первым,
        // он добавлял таймаут к каждому резолву на старте.
        let list = BuildTunnelConfig.systemDNSList(profileDNS: ["100.64.0.1", "8.8.4.4"])
        XCTAssertEqual(list.first, "8.8.4.4")
        XCTAssertTrue(list.contains("100.64.0.1"), "внутренний DNS не выбрасываем, только двигаем")
        XCTAssertLessThan(list.firstIndex(of: "1.1.1.1")!, list.firstIndex(of: "100.64.0.1")!)
    }

    func testSystemDNSDeduplicates() {
        let list = BuildTunnelConfig.systemDNSList(profileDNS: ["1.1.1.1", "1.1.1.1", " 8.8.8.8 "])
        XCTAssertEqual(list, ["1.1.1.1", "8.8.8.8"])
    }
}

