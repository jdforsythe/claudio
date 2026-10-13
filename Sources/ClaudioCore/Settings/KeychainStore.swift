import Foundation
import Security

/// Generic-password Keychain access for the OpenAI key (document 08 §3).
public struct KeychainStore: Sendable {
    public static let service = "com.jdforsythe.claudio"

    public enum Account: String, Sendable {
        case openAI = "openai"
    }

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case encoding
    }

    public let service: String

    public init(service: String = KeychainStore.service) {
        self.service = service
    }

    private func query(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    public func set(_ secret: String, for account: Account) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.encoding }
        var q = query(account)
        let found = SecItemCopyMatching(q as CFDictionary, nil)
        if found == errSecSuccess {
            let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        } else {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(q as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }
    }

    public func get(_ account: Account) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ account: Account) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func exists(_ account: Account) -> Bool {
        (try? get(account)) != nil
    }
}
