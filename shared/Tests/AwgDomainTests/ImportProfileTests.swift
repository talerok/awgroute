import XCTest
@testable import AwgDomain

final class ImportProfileTests: XCTestCase {

    private var parser: FakeParser!
    private var repo: FakeProfileRepo!
    private var secrets: FakeSecrets!
    private let id = UUID()

    override func setUp() {
        super.setUp()
        parser = FakeParser(); repo = FakeProfileRepo(); secrets = FakeSecrets()
    }

    private func makeSUT() -> ImportProfile {
        ImportProfile(parser: parser, repository: repo, secrets: secrets,
                      now: { Date(timeIntervalSince1970: 0) }, newID: { self.id })
    }

    func testSecretsGoToStoreAndProfileKeepsPlaceholders() throws {
        var config = Sample.config()
        config.interface.privateKey = "real-private-key"
        config.peers[0].presharedKey = "real-psk"
        parser.result = (config, [])

        let result = try makeSUT()(confText: "irrelevant", name: "de")

        XCTAssertEqual(secrets.privateKeys[id], "real-private-key")
        XCTAssertEqual(secrets.psks["\(id)-0"], "real-psk")
        // На диск секреты не попадают ни при каких обстоятельствах.
        XCTAssertEqual(result.profile.config.interface.privateKey, Profile.secretPlaceholder)
        XCTAssertEqual(result.profile.config.peers[0].presharedKey, Profile.secretPlaceholder)
        XCTAssertEqual(repo.stored[id]?.name, "de")
    }

    func testWarningsAreSurfaced() throws {
        parser.result = (Sample.config(), ["Unknown [Interface] key: Foo"])
        let result = try makeSUT()(confText: "x", name: "p")
        XCTAssertEqual(result.warnings, ["Unknown [Interface] key: Foo"])
    }

    func testFailedSaveRollsBackKeychain() {
        var config = Sample.config()
        config.interface.privateKey = "real-private-key"
        parser.result = (config, [])
        repo.saveError = NSError(domain: "disk", code: 1)

        XCTAssertThrowsError(try makeSUT()(confText: "x", name: "p"))
        // Без отката в Keychain остался бы секрет от профиля, которого нет.
        XCTAssertNil(secrets.privateKeys[id], "секрет должен быть откачен")
        XCTAssertTrue(repo.stored.isEmpty)
    }

    func testParserFailurePropagates() {
        parser.error = AwgConfigError.missingSection("Interface")
        XCTAssertThrowsError(try makeSUT()(confText: "junk", name: "p")) { error in
            XCTAssertEqual(error as? AwgConfigError, .missingSection("Interface"))
        }
        XCTAssertTrue(secrets.privateKeys.isEmpty)
    }
}

final class ReconnectTunnelTests: XCTestCase {

    private func makeSUT(gateway: FakeGateway, network: FakeNetwork,
                         status: @escaping @Sendable () async -> TunnelStatus) -> ReconnectTunnel {
        let secrets = FakeSecrets()
        let id = UUID(); secrets.privateKeys[id] = "pk"
        let build = BuildTunnelConfig(
            renderer: FakeRenderer(), validator: nil,
            materialize: MaterializeProfile(secrets: secrets),
            rules: FakeRules(), paths: StubPaths(),
            secretGenerator: StubSecretGen(value: "s")
        )
        return ReconnectTunnel(
            connect: ConnectTunnel(build: build, gateway: gateway),
            network: network,
            status: status,
            // Без реальных пауз в тесте.
            sleep: { _ in }
        )
    }

    func testWaitsForNetworkBeforeHandshake() async {
        let gateway = FakeGateway(); let network = FakeNetwork()
        let secrets = FakeSecrets(); let id = UUID(); secrets.privateKeys[id] = "pk"
        _ = await makeSUT(gateway: gateway, network: network, status: { .running(pid: 1) })(
            profile: Sample.profile(id))
        XCTAssertEqual(network.waitCalls, 1, "хендшейк в мёртвый интерфейс уходит в никуда")
    }

    func testUsesRestartNotStart() async {
        let gateway = FakeGateway(); let network = FakeNetwork()
        let id = UUID()
        // Секрет кладём в тот же store, что и SUT.
        let sut = makeSUTWithSecrets(gateway: gateway, network: network, profileID: id)
        _ = await sut(profile: Sample.profile(id))
        XCTAssertTrue(gateway.startCalls.isEmpty, "connect был бы no-op на живом процессе")
        XCTAssertFalse(gateway.restartCalls.isEmpty)
    }

    func testGivesUpAfterConfiguredAttempts() async {
        let gateway = FakeGateway(); let network = FakeNetwork()
        gateway.errorToThrow = TunnelError.gateway("boom")
        let id = UUID()
        let sut = makeSUTWithSecrets(gateway: gateway, network: network, profileID: id)
        let result = await sut(profile: Sample.profile(id))
        XCTAssertFalse(result.isRunning)
    }

    private func makeSUTWithSecrets(gateway: FakeGateway, network: FakeNetwork,
                                    profileID: UUID) -> ReconnectTunnel {
        let secrets = FakeSecrets(); secrets.privateKeys[profileID] = "pk"
        let build = BuildTunnelConfig(
            renderer: FakeRenderer(), validator: nil,
            materialize: MaterializeProfile(secrets: secrets),
            rules: FakeRules(), paths: StubPaths(),
            secretGenerator: StubSecretGen(value: "s")
        )
        return ReconnectTunnel(
            connect: ConnectTunnel(build: build, gateway: gateway),
            network: network, status: { .running(pid: 1) }, sleep: { _ in }
        )
    }
}
