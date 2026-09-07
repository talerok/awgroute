import Foundation
import Security
import AwgDomain

/// Реализация `SecretStore` поверх Keychain.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: читается только когда пользователь
/// вошёл, и не уезжает в iCloud-бэкап — AWG-ключ привязан к устройству, синхронизировать
/// его бессмысленно и опасно.
public struct KeychainSecretStore: SecretStore {
    public init() {}


    static let serviceName = "dev.awgroute.profile-private-key"

    public enum Failure: Error, LocalizedError {
        case osStatus(OSStatus, op: String)
        case notUTF8
        public var errorDescription: String? {
            switch self {
            case .osStatus(let s, let op): return "Keychain \(op) failed: \(s)"
            case .notUTF8:                 return "Keychain value is not UTF-8"
            }
        }
    }

    // MARK: SecretStore

    public func privateKey(profileID: UUID) throws -> String? {
        try get(account: Accounts.privateKey(profileID))
    }
    public func setPrivateKey(_ value: String, profileID: UUID) throws {
        try set(value, account: Accounts.privateKey(profileID))
    }
    public func presharedKey(profileID: UUID, peerIndex: Int) throws -> String? {
        try get(account: Accounts.peerPSK(profileID, peerIndex))
    }
    public func setPresharedKey(_ value: String, profileID: UUID, peerIndex: Int) throws {
        try set(value, account: Accounts.peerPSK(profileID, peerIndex))
    }
    public func deleteAll(profileID: UUID, peerCount: Int) {
        delete(account: Accounts.privateKey(profileID))
        for i in 0..<max(peerCount, 0) { delete(account: Accounts.peerPSK(profileID, i)) }
    }

    // MARK: - Private

    private enum Accounts {
        static func privateKey(_ id: UUID) -> String { "interface-pk-\(id.uuidString)" }
        static func peerPSK(_ id: UUID, _ index: Int) -> String { "peer-psk-\(id.uuidString)-\(index)" }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account
        ]
    }

    private func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account)
        // Атомарный upsert: сначала update, потом add. В отличие от delete+add нет
        // окна, в котором секрета нет в Keychain.
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw Failure.osStatus(updateStatus, op: "update") }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.osStatus(addStatus, op: "add") }
    }

    private func get(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.osStatus(status, op: "get") }
        guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            throw Failure.notUTF8
        }
        return s
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

/// Реализация `SecretGenerating` на системном CSPRNG.
///
/// Помнит последний выданный секрет: его генерирует сценарий подключения (он попадает
/// в конфиг backend'а), а предъявлять его должна телеметрия. Общий объект — явная
/// связь между ними, вместо статической переменной, о которой знают все и никто.
public final class ClashSecretProvider: SecretGenerating, @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var value: String?

    public var current: String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let s = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock(); value = s; lock.unlock()
        return s
    }
}
