import Foundation
import MackyCore

/// Keeps the (free) Spotify developer app credentials in the Keychain.
/// They are only used to SEARCH Spotify's catalog (song name → Spotify link);
/// playback itself goes through the Spotify app on the Mac.
@MainActor
final class SpotifyCredentialsStore: ObservableObject {
    private static let keychainService = "com.flowfulmedia.macky.spotify"

    @Published private(set) var hasCredentials: Bool
    private(set) var clientIdentifier: String?
    private(set) var clientSecret: String?

    init() {
        clientIdentifier = KeychainStore.readString(service: Self.keychainService, account: "client-id")
        clientSecret = KeychainStore.readString(service: Self.keychainService, account: "client-secret")
        hasCredentials = !(clientIdentifier ?? "").isEmpty && !(clientSecret ?? "").isEmpty
    }

    func save(clientIdentifier: String, clientSecret: String) throws {
        let trimmedIdentifier = clientIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainStore.writeString(trimmedIdentifier, service: Self.keychainService, account: "client-id")
        try KeychainStore.writeString(trimmedSecret, service: Self.keychainService, account: "client-secret")
        self.clientIdentifier = trimmedIdentifier
        self.clientSecret = trimmedSecret
        hasCredentials = !trimmedIdentifier.isEmpty && !trimmedSecret.isEmpty
    }

    func remove() {
        KeychainStore.delete(service: Self.keychainService, account: "client-id")
        KeychainStore.delete(service: Self.keychainService, account: "client-secret")
        clientIdentifier = nil
        clientSecret = nil
        hasCredentials = false
    }
}

enum SpotifyWebAPIError: LocalizedError {
    case authenticationFailed(String)
    case nothingFound
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let details): return "Datele Spotify nu sunt valide (\(details))."
        case .nothingFound: return "Spotify nu a găsit nimic."
        case .unexpectedResponse: return "Spotify a răspuns neașteptat."
        }
    }
}

/// Searches Spotify with the "client credentials" flow: no Spotify login and no Premium needed.
final class SpotifyWebAPIClient: @unchecked Sendable {
    struct SearchResult {
        var uri: String
        var name: String
        var artistName: String?
    }

    private let urlSession = URLSession(configuration: .default)
    private let tokenLock = NSLock()
    private var cachedAccessToken: String?
    private var cachedAccessTokenExpiryDate = Date.distantPast

    func search(query: String, kind: SpotifySearchKind, clientIdentifier: String, clientSecret: String) async throws -> SearchResult {
        let accessToken = try await accessToken(clientIdentifier: clientIdentifier, clientSecret: clientSecret)
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: kind.rawValue),
            URLQueryItem(name: "limit", value: "5")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = json[kind.rawValue + "s"] as? [String: Any],
              let items = section["items"] as? [Any] else {
            throw SpotifyWebAPIError.unexpectedResponse
        }
        // Playlist results can contain nulls for removed playlists.
        guard let firstItem = items.compactMap({ $0 as? [String: Any] }).first(where: { $0["uri"] is String }),
              let uri = firstItem["uri"] as? String else {
            throw SpotifyWebAPIError.nothingFound
        }
        let artistName = (firstItem["artists"] as? [[String: Any]])?.first?["name"] as? String
            ?? ((firstItem["owner"] as? [String: Any])?["display_name"] as? String)
        return SearchResult(uri: uri, name: firstItem["name"] as? String ?? query, artistName: artistName)
    }

    /// Tokens last an hour; one is reused so a search costs a single request.
    func accessToken(clientIdentifier: String, clientSecret: String) async throws -> String {
        tokenLock.lock()
        if let cachedAccessToken, cachedAccessTokenExpiryDate > Date().addingTimeInterval(60) {
            tokenLock.unlock()
            return cachedAccessToken
        }
        tokenLock.unlock()

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        let basicCredentials = Data("\(clientIdentifier):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basicCredentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        request.timeoutInterval = 8

        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw SpotifyWebAPIError.authenticationFailed("HTTP \(statusCode)")
        }
        let lifetimeInSeconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        tokenLock.lock()
        cachedAccessToken = accessToken
        cachedAccessTokenExpiryDate = Date().addingTimeInterval(lifetimeInSeconds)
        tokenLock.unlock()
        return accessToken
    }
}
