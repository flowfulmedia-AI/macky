import Foundation

/// OAuth for MCP servers (MCP authorization spec): the server names its authorization server in
/// "protected resource" metadata; Macky registers itself as a public client (dynamic client registration),
/// the user approves once in the browser (PKCE, loopback redirect), and tokens refresh by themselves.
public enum MCPOAuth {
    public static let defaultScope = "openid email profile"

    public struct AuthorizationServerMetadata: Codable, Equatable, Sendable {
        public var issuer: String?
        public var authorizationEndpoint: String
        public var tokenEndpoint: String
        public var registrationEndpoint: String?
        public var scopesSupported: [String]?
    }

    /// What Macky keeps (in the Keychain) to call the server without asking the user again.
    public struct StoredCredentials: Codable, Equatable, Sendable {
        public var clientIdentifier: String
        public var tokenEndpoint: String
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?

        public init(clientIdentifier: String, tokenEndpoint: String, accessToken: String, refreshToken: String?, expiresAt: Date?) {
            self.clientIdentifier = clientIdentifier
            self.tokenEndpoint = tokenEndpoint
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }

        public func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return now >= expiresAt.addingTimeInterval(-60)
        }

        /// Stores new tokens; a refresh that returns no new refresh token keeps the old one.
        public func updated(with tokens: GoogleOAuth.Tokens, now: Date = Date()) -> StoredCredentials {
            var copy = self
            copy.accessToken = tokens.accessToken
            copy.refreshToken = tokens.refreshToken ?? refreshToken
            copy.expiresAt = now.addingTimeInterval(tokens.expiresInSeconds)
            return copy
        }
    }

    /// Where the server's protected resource metadata may be, most specific first.
    public static func protectedResourceMetadataURLs(mcpURL: URL, wwwAuthenticateHeader: String?) -> [URL] {
        var urls: [URL] = []
        if let header = wwwAuthenticateHeader, let advertised = resourceMetadataURL(fromWWWAuthenticate: header) {
            urls.append(advertised)
        }
        if let origin = origin(of: mcpURL) {
            let path = mcpURL.path == "/" ? "" : mcpURL.path
            if !path.isEmpty, let withPath = URL(string: origin + "/.well-known/oauth-protected-resource" + path) { urls.append(withPath) }
            if let plain = URL(string: origin + "/.well-known/oauth-protected-resource") { urls.append(plain) }
        }
        return unique(urls)
    }

    /// Reads resource_metadata="…" from a 401's WWW-Authenticate header.
    public static func resourceMetadataURL(fromWWWAuthenticate header: String) -> URL? {
        guard let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else { return nil }
        let value = header[range].dropFirst("resource_metadata=\"".count).dropLast()
        return URL(string: String(value))
    }

    public static func authorizationServer(fromProtectedResourceMetadata data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["authorization_servers"] as? [String])?.first
    }

    /// RFC 8414 and OpenID discovery locations for an issuer, including issuers with a path.
    public static func authorizationServerMetadataURLs(issuer: String) -> [URL] {
        let trimmedIssuer = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        guard let issuerURL = URL(string: trimmedIssuer), let origin = origin(of: issuerURL) else { return [] }
        let path = issuerURL.path == "/" ? "" : issuerURL.path
        var candidates = [
            origin + "/.well-known/oauth-authorization-server" + path,
            trimmedIssuer + "/.well-known/oauth-authorization-server",
            origin + "/.well-known/openid-configuration" + path,
            trimmedIssuer + "/.well-known/openid-configuration"
        ]
        if path.isEmpty { candidates = [origin + "/.well-known/oauth-authorization-server", origin + "/.well-known/openid-configuration"] }
        return unique(candidates.compactMap(URL.init(string:)))
    }

    public static func parseAuthorizationServerMetadata(_ data: Data) -> AuthorizationServerMetadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authorizationEndpoint = json["authorization_endpoint"] as? String,
              let tokenEndpoint = json["token_endpoint"] as? String else { return nil }
        return AuthorizationServerMetadata(
            issuer: json["issuer"] as? String,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            registrationEndpoint: json["registration_endpoint"] as? String,
            scopesSupported: json["scopes_supported"] as? [String]
        )
    }

    public static func registrationRequestBody(redirectURI: String) -> Data {
        let body: [String: Any] = [
            "client_name": "Macky",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    public static func parseClientIdentifier(fromRegistrationResponse data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["client_id"] as? String
    }

    public static func scope(for metadata: AuthorizationServerMetadata) -> String {
        guard let supported = metadata.scopesSupported, !supported.isEmpty, !supported.contains("openid") else { return defaultScope }
        return supported.joined(separator: " ")
    }

    public static func authorizationURL(metadata: AuthorizationServerMetadata, clientIdentifier: String, redirectURI: String,
                                        codeChallenge: String, state: String) -> URL? {
        guard var components = URLComponents(string: metadata.authorizationEndpoint) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientIdentifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scope(for: metadata))
        ]
        return components.url
    }

    public static func authorizationCodeRequestBody(code: String, clientIdentifier: String, redirectURI: String, codeVerifier: String) -> Data {
        GoogleOAuth.formEncoded([
            ("grant_type", "authorization_code"), ("client_id", clientIdentifier), ("code", code),
            ("code_verifier", codeVerifier), ("redirect_uri", redirectURI)
        ])
    }

    public static func refreshRequestBody(clientIdentifier: String, refreshToken: String) -> Data {
        GoogleOAuth.formEncoded([("grant_type", "refresh_token"), ("client_id", clientIdentifier), ("refresh_token", refreshToken)])
    }

    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }
}
