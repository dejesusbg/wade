import Foundation
import Security

/// Cloud API keys, one per vendor, kept in the user's login Keychain (never in UserDefaults or
/// on disk).
public enum APIKeyStore {
    private static let service = "com.ricardo.wade.api-keys"

    public static func read(_ vendor: Vendor) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor.rawValue,
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
    public static func save(_ key: String, for vendor: Vendor) -> Bool {
        delete(vendor)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor.rawValue,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(_ vendor: Vendor) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vendor.rawValue,
        ] as CFDictionary)
    }
}
