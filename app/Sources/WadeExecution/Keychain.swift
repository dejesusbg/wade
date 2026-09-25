import Foundation
import Security

/// Secrets (cloud API keys, one per vendor, plus integration tokens such as GitHub's), kept in
/// the user's login Keychain, never in UserDefaults or on disk.
public enum APIKeyStore {
    private static let service = "com.ricardo.wade.api-keys"

    public static func read(_ vendor: Vendor) -> String? { read(account: vendor.rawValue) }
    @discardableResult
    public static func save(_ key: String, for vendor: Vendor) -> Bool { save(key, account: vendor.rawValue) }
    public static func delete(_ vendor: Vendor) { delete(account: vendor.rawValue) }

    public static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    public static func save(_ key: String, account: String) -> Bool {
        delete(account: account)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
