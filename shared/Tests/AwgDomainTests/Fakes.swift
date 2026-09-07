import Foundation
@testable import AwgDomain

// Подделки портов. Ровно ради этого домен и отделён: сценарии проверяются
// без macOS, без root, без helper'а и без реального backend'а.

final class FakeGateway: TunnelGateway, @unchecked Sendable {
    var isAvailable = true
    var statusToReturn: TunnelStatus = .stopped
    var errorToThrow: Error?
    private(set) var startCalls: [(Data, [String])] = []
    private(set) var restartCalls: [(Data, [String])] = []
    private(set) var stopCalls = 0

    func start(config: Data, dnsServers: [String]) async throws -> TunnelStatus {
        if let errorToThrow { throw errorToThrow }
        startCalls.append((config, dnsServers))
        return .running(pid: 42)
    }
    func restart(config: Data, dnsServers: [String]) async throws -> TunnelStatus {
        if let errorToThrow { throw errorToThrow }
        restartCalls.append((config, dnsServers))
        return .running(pid: 43)
    }
    func stop() async throws { stopCalls += 1 }
    func status() async throws -> TunnelStatus { statusToReturn }
    func events() -> AsyncStream<TunnelStatus> { AsyncStream { $0.finish() } }
}

final class FakeSecrets: SecretStore, @unchecked Sendable {
    var privateKeys: [UUID: String] = [:]
    var psks: [String: String] = [:]
    func privateKey(profileID: UUID) throws -> String? { privateKeys[profileID] }
    func setPrivateKey(_ value: String, profileID: UUID) throws { privateKeys[profileID] = value }
    func presharedKey(profileID: UUID, peerIndex: Int) throws -> String? { psks["\(profileID)-\(peerIndex)"] }
    func setPresharedKey(_ value: String, profileID: UUID, peerIndex: Int) throws { psks["\(profileID)-\(peerIndex)"] = value }
    func deleteAll(profileID: UUID, peerCount: Int) {
        privateKeys[profileID] = nil
        for i in 0..<max(peerCount, 0) { psks["\(profileID)-\(i)"] = nil }
    }
}

final class FakeRules: RulesRepository, @unchecked Sendable {
    var rules: RoutingRules = .empty
    func load() -> RoutingRules { rules }
    func save(_ rules: RoutingRules) throws { self.rules = rules }
}

final class FakeRenderer: ConfigRendering, @unchecked Sendable {
    var validation: RulesValidation = .ok
    var renderError: Error?
    private(set) var lastOptions: RenderOptions?
    func render(config: AwgConfig, rules: RoutingRules?, options: RenderOptions) throws -> Data {
        if let renderError { throw renderError }
        lastOptions = options
        return Data("{}".utf8)
    }
    func validate(rules: RoutingRules) -> RulesValidation { validation }
}

final class FakeValidator: ConfigValidating, @unchecked Sendable {
    var problem: String?
    func validate(config: Data) async -> String? { problem }
}

struct StubPaths: RuntimePaths {
    var backendCache = "/tmp/awgroute-test/cache.db"
    var backendLog = "/tmp/awgroute-test/backend.log"
}

final class FakeParser: ConfigParsing, @unchecked Sendable {
    var result: (config: AwgConfig, warnings: [String]) = (Sample.config(), [])
    var error: Error?
    func parse(_ text: String) throws -> (config: AwgConfig, warnings: [String]) {
        if let error { throw error }
        return result
    }
}

final class FakeProfileRepo: ProfileRepository, @unchecked Sendable {
    var stored: [UUID: Profile] = [:]
    var saveError: Error?
    func load() throws -> [Profile] { Array(stored.values) }
    func save(_ profile: Profile) throws {
        if let saveError { throw saveError }
        stored[profile.id] = profile
    }
    func delete(id: UUID) throws { stored[id] = nil }
}

final class FakeNetwork: NetworkMonitoring, @unchecked Sendable {
    var pathAvailable = true
    private(set) var waitCalls = 0
    func pathUpdates() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
    func waitForPath(timeout: TimeInterval) async -> Bool {
        waitCalls += 1
        return pathAvailable
    }
}

struct StubSecretGen: SecretGenerating {
    let value: String
    func newSecret() -> String { value }
}

enum Sample {
    static func config(dns: [String] = [], withPSK: Bool = false) -> AwgConfig {
        AwgConfig(
            interface: .init(address: ["10.0.0.1/32"], privateKey: Profile.secretPlaceholder, dns: dns),
            peers: [.init(publicKey: "pub",
                          presharedKey: withPSK ? Profile.secretPlaceholder : nil,
                          endpointHost: "1.2.3.4", endpointPort: 51820,
                          allowedIPs: ["0.0.0.0/0"])]
        )
    }
    static func profile(_ id: UUID = UUID(), dns: [String] = [], withPSK: Bool = false) -> Profile {
        Profile(id: id, name: "test", createdAt: Date(), config: config(dns: dns, withPSK: withPSK))
    }
}
