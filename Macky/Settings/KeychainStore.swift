import Foundation
import Security

enum KeychainStore {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let systemMessage = SecCopyErrorMessageString(status, nil) as String? ?? "cod \(status)"
                return "Keychain: \(systemMessage)"
            }
        }
    }

    static func readString(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func writeString(_ value: String, service: String, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let valueData = Data(value.utf8)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: valueData] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = valueData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class OpenRouterAPIKeyStore: ObservableObject {
    private static let keychainService = "com.flowfulmedia.macky.openrouter"
    private static let keychainAccount = "api-key"

    @Published private(set) var hasAPIKey: Bool
    /// Read once and kept in memory so every question does not hit the Keychain.
    private var cachedAPIKey: String?

    init() {
        cachedAPIKey = KeychainStore.readString(service: Self.keychainService, account: Self.keychainAccount)
        hasAPIKey = !(cachedAPIKey ?? "").isEmpty
    }

    func apiKey() -> String? {
        cachedAPIKey
    }

    func save(_ apiKey: String) throws {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainStore.writeString(trimmedAPIKey, service: Self.keychainService, account: Self.keychainAccount)
        cachedAPIKey = trimmedAPIKey
        hasAPIKey = !trimmedAPIKey.isEmpty
    }

    func remove() {
        KeychainStore.delete(service: Self.keychainService, account: Self.keychainAccount)
        cachedAPIKey = nil
        hasAPIKey = false
    }
}
