import Foundation
import Security

/// Where Macky keeps keys and tokens (OpenRouter, Google, Zoom, Spotify, connected apps).
///
/// They live in ~/Library/Application Support/Macky/secrets.json, readable only by your macOS user
/// (permissions 600, folder 700; encrypted at rest by FileVault). Not in the Keychain: without a paid Apple
/// developer account, macOS ties every Keychain item to the exact app binary, so each update would ask
/// for the Mac password once per saved key. Secrets saved in the Keychain by older versions are moved
/// here the first time they are read (macOS asks one last time).
enum KeychainStore {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case fileWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let systemMessage = SecCopyErrorMessageString(status, nil) as String? ?? "cod \(status)"
                return "Keychain: \(systemMessage)"
            case .fileWriteFailed(let reason):
                return "Nu am putut salva: \(reason)"
            }
        }
    }

    private static let lock = NSLock()
    private static var cache: [String: String]?

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Macky", isDirectory: true).appendingPathComponent("secrets.json")
    }

    private static func key(service: String, account: String) -> String { "\(service)|\(account)" }

    /// Must be called with the lock held.
    private static func loadedSecrets() -> [String: String] {
        if let cache { return cache }
        let secrets = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = secrets
        return secrets
    }

    /// Must be called with the lock held.
    private static func persist(_ secrets: [String: String]) throws {
        let folderURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folderURL.path)
        let data = try JSONEncoder().encode(secrets)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw KeychainError.fileWriteFailed(fileURL.path)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cache = secrets
    }

    static func readString(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let secretKey = key(service: service, account: account)
        var secrets = loadedSecrets()
        if let value = secrets[secretKey] { return value }
        // Moves a secret saved by an older version out of the Keychain. Marked as done only when it was
        // moved or truly is not there: if the password prompt was cancelled, it asks again next launch.
        let migratedMarker = secretKey + Self.checkedMarkerSuffix
        guard secrets[migratedMarker] == nil else { return nil }
        let legacyRead = readLegacyKeychainString(service: service, account: account)
        if let value = legacyRead.value {
            secrets[secretKey] = value
            secrets[migratedMarker] = "1"
            try? persist(secrets)
        } else if legacyRead.status == errSecItemNotFound {
            secrets[migratedMarker] = "1"
            try? persist(secrets)
        }
        return legacyRead.value
    }

    /// "-v2": the first version also marked secrets whose password prompt was cancelled, so they were never moved.
    private static let checkedMarkerSuffix = "|checked-keychain-v2"

    static func writeString(_ value: String, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var secrets = loadedSecrets()
        secrets[key(service: service, account: account)] = value
        try persist(secrets)
    }

    static func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        var secrets = loadedSecrets()
        let secretKey = key(service: service, account: account)
        secrets[secretKey] = nil
        // Do not look in the Keychain again for something deliberately removed.
        secrets[secretKey + Self.checkedMarkerSuffix] = "1"
        try? persist(secrets)
    }

    private static func readLegacyKeychainString(service: String, account: String) -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
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
