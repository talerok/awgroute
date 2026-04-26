import Foundation
import Security

/// Очень тонкая обёртка над Security.framework для хранения секретов AwgRoute.
/// `kSecClassGenericPassword`, `kSecAttrService = "dev.awgroute.profile-private-key"`,
/// доступ — `kSecAttrAccessibleAfterFirstUnlock`.
enum KeychainStore {

    static let serviceName = "dev.awgroute.profile-private-key"

    enum Error: Swift.Error, LocalizedError {
        case osStatus(OSStatus, op: String)
        case decodingFailed
        var errorDescription: String? {
            switch self {
            case .osStatus(let s, let op): return "Keychain \(op) failed: \(s)"
            case .decodingFailed:          return "Keychain value is not UTF-8"
            }
        }
    }

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        // Сначала удалить (upsert)
        let delQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(delQuery as CFDictionary)

        var addQuery = delQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.osStatus(status, op: "add") }
    }

    static func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Error.osStatus(status, op: "get") }
        guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            throw Error.decodingFailed
        }
        return s
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Удалить все секреты, относящиеся к profile.id.
    static func deleteAll(forProfile id: UUID) {
        delete(account: ProfileSecretAccounts.privateKey(profileID: id))
        // Удалить все peer-psk-<id>-* — итерируем до 16 (запас на multi-peer)
        for i in 0..<16 {
            delete(account: ProfileSecretAccounts.peerPSK(profileID: id, peerIndex: i))
        }
    }
}

enum ProfileSecretAccounts {
    static func privateKey(profileID: UUID) -> String { "interface-pk-\(profileID.uuidString)" }
    static func peerPSK(profileID: UUID, peerIndex: Int) -> String { "peer-psk-\(profileID.uuidString)-\(peerIndex)" }
}
