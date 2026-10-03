import Foundation

/// Google sign-in (OAuth 2.0 for desktop apps, with PKCE and a loopback redirect) and the few Gmail
/// and Drive calls Macky needs. Gmail is read-only; Drive can be written so agents can save documents
/// into the user's own folders (Macky only ever creates new files there, it never edits or deletes).
public enum GoogleOAuth {
    public static let driveScope = "https://www.googleapis.com/auth/drive"
    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        driveScope
    ]

    /// True when the scopes Google granted include writing to any Drive folder.
    public static func grantsDriveWrite(_ grantedScope: String?) -> Bool {
        guard let grantedScope else { return false }
        return grantedScope.split(separator: " ").contains { $0 == driveScope }
    }
    public static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public static func authorizationURL(clientIdentifier: String, redirectURI: String, codeChallenge: String, state: String) -> URL {
        var components = URLComponents(string: authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientIdentifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // A refresh token, so the user signs in only once.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    public static func authorizationCodeRequestBody(code: String, clientIdentifier: String, clientSecret: String, redirectURI: String, codeVerifier: String) -> Data {
        formEncoded([
            ("code", code), ("client_id", clientIdentifier), ("client_secret", clientSecret),
            ("redirect_uri", redirectURI), ("grant_type", "authorization_code"), ("code_verifier", codeVerifier)
        ])
    }

    public static func refreshRequestBody(refreshToken: String, clientIdentifier: String, clientSecret: String) -> Data {
        formEncoded([
            ("refresh_token", refreshToken), ("client_id", clientIdentifier), ("client_secret", clientSecret), ("grant_type", "refresh_token")
        ])
    }

    public struct Tokens: Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresInSeconds: Double
        public var grantedScope: String?
    }

    public struct OAuthError: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }

        public init(message: String) {
            self.message = message
        }
    }

    public static func parseTokenResponse(_ data: Data) throws -> Tokens {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError(message: "Răspuns neașteptat de la Google.")
        }
        if let error = json["error"] as? String {
            let description = (json["error_description"] as? String).map { ": \($0)" } ?? ""
            throw OAuthError(message: "Google a refuzat autentificarea (\(error)\(description)).")
        }
        guard let accessToken = json["access_token"] as? String else {
            throw OAuthError(message: "Google nu a trimis un token de acces.")
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Tokens(accessToken: accessToken, refreshToken: json["refresh_token"] as? String, expiresInSeconds: expiresIn,
                      grantedScope: json["scope"] as? String)
    }

    public struct AuthorizationCallback: Equatable, Sendable {
        public var code: String?
        public var state: String?
        public var error: String?
    }

    /// Reads the browser's redirect ("GET /?code=…&state=… HTTP/1.1") received by the loopback listener.
    public static func parseCallback(requestText: String) -> AuthorizationCallback? {
        guard let firstLine = requestText.components(separatedBy: "\r\n").first ?? requestText.components(separatedBy: "\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("code") != nil || value("error") != nil else { return nil }
        return AuthorizationCallback(code: value("code"), state: value("state"), error: value("error"))
    }

    /// PKCE code verifier: 64 characters from the unreserved URL set.
    public static func makeCodeVerifier() -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in characters.randomElement()! })
    }

    /// base64url without padding, as PKCE wants for the SHA-256 of the verifier.
    public static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    static func formEncoded(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - Gmail

public struct GmailMessage: Equatable, Sendable {
    public var identifier: String
    public var from: String
    public var to: String
    public var subject: String
    public var date: String
    public var snippet: String
    public var bodyText: String
    public var isUnread: Bool

    /// One line for a list of results.
    public var summaryLine: String {
        "id=\(identifier) | \(date) | from: \(from) | subject: \(subject)\(isUnread ? " | UNREAD" : "") | \(snippet)"
    }
}

public enum GmailAPI {
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me/messages"

    public static func searchURL(query: String, maximumResults: Int = 10) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(maximumResults))]
        return components.url!
    }

    public static func messageURL(identifier: String, full: Bool) -> URL {
        var components = URLComponents(string: "\(base)/\(identifier)")!
        if full {
            components.queryItems = [URLQueryItem(name: "format", value: "full")]
        } else {
            components.queryItems = [URLQueryItem(name: "format", value: "metadata")]
                + ["From", "To", "Subject", "Date"].map { URLQueryItem(name: "metadataHeaders", value: $0) }
        }
        return components.url!
    }

    public static func parseMessageIdentifiers(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { $0["id"] as? String }
    }

    public static func parseMessage(_ data: Data) -> GmailMessage? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = json["id"] as? String else { return nil }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = (payload["headers"] as? [[String: Any]]) ?? []
        func header(_ name: String) -> String {
            (headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String) ?? ""
        }
        let labels = (json["labelIds"] as? [String]) ?? []
        let snippet = HTMLTextExtractor.decodeEntities((json["snippet"] as? String) ?? "")
        return GmailMessage(
            identifier: identifier, from: header("From"), to: header("To"), subject: header("Subject"), date: header("Date"),
            snippet: snippet, bodyText: bodyText(of: payload), isUnread: labels.contains("UNREAD")
        )
    }

    /// Prefers the plain-text part; falls back to the HTML part converted to text.
    static func bodyText(of payload: [String: Any]) -> String {
        var plainParts: [String] = []
        var htmlParts: [String] = []
        func walk(_ part: [String: Any]) {
            let mimeType = (part["mimeType"] as? String)?.lowercased() ?? ""
            if let body = part["body"] as? [String: Any], let encoded = body["data"] as? String,
               let decoded = GoogleOAuth.base64URLDecoded(encoded), let text = String(data: decoded, encoding: .utf8) {
                if mimeType == "text/plain" { plainParts.append(text) }
                if mimeType == "text/html" { htmlParts.append(text) }
            }
            for child in (part["parts"] as? [[String: Any]]) ?? [] { walk(child) }
        }
        walk(payload)
        if !plainParts.isEmpty { return plainParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        return htmlParts.map { HTMLTextExtractor.readableText(fromHTML: $0, maximumCharacters: 20_000) }.joined(separator: "\n")
    }

    public static func readableMessage(_ message: GmailMessage, maximumCharacters: Int = 8000) -> String {
        let body = message.bodyText.isEmpty ? message.snippet : message.bodyText
        let shownBody = body.count > maximumCharacters ? String(body.prefix(maximumCharacters)) + "\n[…truncated]" : body
        return "From: \(message.from)\nTo: \(message.to)\nDate: \(message.date)\nSubject: \(message.subject)\n\n\(shownBody)"
    }
}

// MARK: - Google Drive

public struct DriveFile: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var mimeType: String
    public var modifiedTime: String
    public var webViewLink: String?
    public var owner: String?

    public var summaryLine: String {
        "id=\(identifier) | \(name) | \(DriveAPI.kindName(for: mimeType)) | modified \(modifiedTime.prefix(10))"
            + (owner.map { " | owner \($0)" } ?? "") + (webViewLink.map { " | link \($0)" } ?? "")
    }
}

public enum DriveAPI {
    static let base = "https://www.googleapis.com/drive/v3/files"

    public static func searchURL(query: String, maximumResults: Int = 10) -> URL {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var components = URLComponents(string: base)!
        components.queryItems = [
            URLQueryItem(name: "q", value: "(name contains '\(escaped)' or fullText contains '\(escaped)') and trashed = false"),
            URLQueryItem(name: "pageSize", value: String(maximumResults)),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,modifiedTime,webViewLink,owners(displayName))"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        return components.url!
    }

    public static func metadataURL(identifier: String) -> URL {
        var components = URLComponents(string: "\(base)/\(identifier)")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,mimeType,modifiedTime,webViewLink,owners(displayName)"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        return components.url!
    }

    /// Google Docs, Sheets and Slides are exported as text; other files are downloaded as they are.
    public static func contentURL(for file: DriveFile) -> (url: URL, isExport: Bool) {
        if let exportType = exportMimeType(for: file.mimeType) {
            var components = URLComponents(string: "\(base)/\(file.identifier)/export")!
            components.queryItems = [URLQueryItem(name: "mimeType", value: exportType)]
            return (components.url!, true)
        }
        var components = URLComponents(string: "\(base)/\(file.identifier)")!
        components.queryItems = [URLQueryItem(name: "alt", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        return (components.url!, false)
    }

    static func exportMimeType(for mimeType: String) -> String? {
        switch mimeType {
        case "application/vnd.google-apps.document", "application/vnd.google-apps.presentation": return "text/plain"
        case "application/vnd.google-apps.spreadsheet": return "text/csv"
        default: return nil
        }
    }

    public static func parseFiles(_ data: Data) -> [DriveFile] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let entries = (json["files"] as? [[String: Any]]) ?? (json["id"] != nil ? [json] : [])
        return entries.compactMap { entry in
            guard let identifier = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            let owner = ((entry["owners"] as? [[String: Any]])?.first?["displayName"]) as? String
            return DriveFile(identifier: identifier, name: name, mimeType: (entry["mimeType"] as? String) ?? "",
                             modifiedTime: (entry["modifiedTime"] as? String) ?? "", webViewLink: entry["webViewLink"] as? String, owner: owner)
        }
    }

    public static func kindName(for mimeType: String) -> String {
        switch mimeType {
        case "application/vnd.google-apps.document": return "Google Doc"
        case "application/vnd.google-apps.spreadsheet": return "Google Sheet"
        case "application/vnd.google-apps.presentation": return "Google Slides"
        case "application/vnd.google-apps.folder": return "folder"
        case "application/pdf": return "PDF"
        default: return mimeType.components(separatedBy: "/").last ?? mimeType
        }
    }
}
