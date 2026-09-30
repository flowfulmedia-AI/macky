import AppKit
import CryptoKit
import Foundation
import MackyCore
import Network

/// The user's Google account, read-only: Gmail search/read and Google Drive search/read.
/// Uses the user's own OAuth client (Google Cloud → "Desktop app"), so nothing goes through a third party.
/// Client ID, client secret and the refresh token live in the Keychain.
@MainActor
final class GoogleAccountManager: ObservableObject {
    private static let keychainService = "com.flowfulmedia.macky.google"

    @Published private(set) var hasClientCredentials: Bool
    @Published private(set) var isConnected: Bool
    @Published private(set) var connectedEmailAddress: String?
    @Published private(set) var statusText: String?
    @Published private(set) var isConnecting = false

    private var clientIdentifier: String?
    private var clientSecret: String?
    private var refreshToken: String?
    private var accessToken: String?
    private var accessTokenExpiryDate: Date?
    private var loopbackListener: NWListener?
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    init() {
        clientIdentifier = KeychainStore.readString(service: Self.keychainService, account: "client-id")
        clientSecret = KeychainStore.readString(service: Self.keychainService, account: "client-secret")
        refreshToken = KeychainStore.readString(service: Self.keychainService, account: "refresh-token")
        connectedEmailAddress = UserDefaults.standard.string(forKey: "googleConnectedEmailAddress")
        hasClientCredentials = !(clientIdentifier ?? "").isEmpty && !(clientSecret ?? "").isEmpty
        isConnected = !(refreshToken ?? "").isEmpty
    }

    func saveClientCredentials(clientIdentifier: String, clientSecret: String) throws {
        let trimmedIdentifier = clientIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainStore.writeString(trimmedIdentifier, service: Self.keychainService, account: "client-id")
        try KeychainStore.writeString(trimmedSecret, service: Self.keychainService, account: "client-secret")
        self.clientIdentifier = trimmedIdentifier
        self.clientSecret = trimmedSecret
        hasClientCredentials = !trimmedIdentifier.isEmpty && !trimmedSecret.isEmpty
    }

    func disconnect() {
        KeychainStore.delete(service: Self.keychainService, account: "refresh-token")
        refreshToken = nil
        accessToken = nil
        accessTokenExpiryDate = nil
        isConnected = false
        connectedEmailAddress = nil
        UserDefaults.standard.removeObject(forKey: "googleConnectedEmailAddress")
        statusText = "Deconectat."
    }

    // MARK: Sign-in

    /// Opens Google's sign-in page in the browser and waits for it to redirect back to a local port.
    func connect() async {
        guard let clientIdentifier, let clientSecret, hasClientCredentials else {
            statusText = "Adaugă întâi Client ID și Client secret."
            return
        }
        isConnecting = true
        statusText = "Se deschide Google în browser…"
        defer {
            isConnecting = false
            loopbackListener?.cancel()
            loopbackListener = nil
        }
        do {
            let codeVerifier = GoogleOAuth.makeCodeVerifier()
            let codeChallenge = GoogleOAuth.base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
            let state = UUID().uuidString
            let (listener, port) = try await startLoopbackListener()
            loopbackListener = listener
            let redirectURI = "http://127.0.0.1:\(port)"
            NSWorkspace.shared.open(GoogleOAuth.authorizationURL(clientIdentifier: clientIdentifier, redirectURI: redirectURI, codeChallenge: codeChallenge, state: state))
            statusText = "Aprobă accesul în browser…"

            let callback = try await waitForCallback(on: listener)
            if let error = callback.error {
                statusText = error == "access_denied" ? "Accesul a fost refuzat." : "Google a răspuns cu eroarea: \(error)"
                return
            }
            guard callback.state == state, let code = callback.code else {
                statusText = "Răspuns neașteptat de la Google. Încearcă din nou."
                return
            }
            var request = URLRequest(url: GoogleOAuth.tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = GoogleOAuth.authorizationCodeRequestBody(code: code, clientIdentifier: clientIdentifier, clientSecret: clientSecret,
                                                                          redirectURI: redirectURI, codeVerifier: codeVerifier)
            let (data, _) = try await urlSession.data(for: request)
            let tokens = try GoogleOAuth.parseTokenResponse(data)
            guard let newRefreshToken = tokens.refreshToken else {
                statusText = "Google nu a trimis un refresh token. Deconectează Macky din contul Google și încearcă din nou."
                return
            }
            try KeychainStore.writeString(newRefreshToken, service: Self.keychainService, account: "refresh-token")
            refreshToken = newRefreshToken
            accessToken = tokens.accessToken
            accessTokenExpiryDate = Date().addingTimeInterval(tokens.expiresInSeconds - 60)
            isConnected = true
            await loadProfile()
            statusText = "Conectat" + (connectedEmailAddress.map { " ca \($0)" } ?? "") + "."
        } catch {
            statusText = "Conectarea a eșuat: \(error.localizedDescription)"
        }
    }

    private func loadProfile() async {
        guard let data = try? await authorizedData(from: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let emailAddress = json["emailAddress"] as? String else { return }
        connectedEmailAddress = emailAddress
        UserDefaults.standard.set(emailAddress, forKey: "googleConnectedEmailAddress")
    }

    private func startLoopbackListener() async throws -> (NWListener, UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let oneShot = OneShotContinuation(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    oneShot.resume(.success((listener, listener.port?.rawValue ?? 0)))
                case .failed(let error):
                    oneShot.resume(.failure(error))
                default:
                    break
                }
            }
            // Connections are accepted later, in waitForCallback.
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: .main)
        }
    }

    /// Waits (up to 5 minutes) for the browser to come back with the authorization code.
    private func waitForCallback(on listener: NWListener) async throws -> GoogleOAuth.AuthorizationCallback {
        try await withCheckedThrowingContinuation { continuation in
            let oneShot = OneShotContinuation(continuation)
            let resume: @Sendable (Result<GoogleOAuth.AuthorizationCallback, Error>) -> Void = { oneShot.resume($0) }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let requestText = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let callback = GoogleOAuth.parseCallback(requestText: requestText)
                    let page = callback == nil
                        ? "<html><body></body></html>"
                        : "<html><head><meta charset='utf-8'></head><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>Macky e conectat la Google.</h2><p>Poți închide această filă.</p></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    if let callback { resume(.success(callback)) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                resume(.failure(GoogleOAuth.OAuthError(message: "Timpul a expirat.")))
            }
        }
    }

    // MARK: Authorized requests

    private func validAccessToken() async throws -> String {
        if let accessToken, let accessTokenExpiryDate, Date() < accessTokenExpiryDate { return accessToken }
        guard let refreshToken, let clientIdentifier, let clientSecret else {
            throw GoogleOAuth.OAuthError(message: "Contul Google nu e conectat. Conectează-l în Setări → Conexiuni.")
        }
        var request = URLRequest(url: GoogleOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuth.refreshRequestBody(refreshToken: refreshToken, clientIdentifier: clientIdentifier, clientSecret: clientSecret)
        let (data, _) = try await urlSession.data(for: request)
        do {
            let tokens = try GoogleOAuth.parseTokenResponse(data)
            accessToken = tokens.accessToken
            accessTokenExpiryDate = Date().addingTimeInterval(tokens.expiresInSeconds - 60)
            return tokens.accessToken
        } catch {
            if String(decoding: data, as: UTF8.self).contains("invalid_grant") {
                // Revoked or expired: the user has to connect again.
                disconnect()
                statusText = "Conectarea Google a expirat. Conectează din nou în Setări → Conexiuni."
            }
            throw error
        }
    }

    private func authorizedData(from url: URL, allowRetry: Bool = true) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode == 401 && allowRetry {
            accessToken = nil
            return try await authorizedData(from: url, allowRetry: false)
        }
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "HTTP \(statusCode)"
            throw GoogleOAuth.OAuthError(message: "Google: \(message)")
        }
        return data
    }

    // MARK: Gmail

    func searchGmail(query: String, maximumResults: Int) async -> String {
        do {
            let identifiers = GmailAPI.parseMessageIdentifiers(try await authorizedData(from: GmailAPI.searchURL(query: query, maximumResults: maximumResults)))
            guard !identifiers.isEmpty else { return "No emails match \"\(query)\"." }
            // One token refresh up front, not one per parallel request.
            _ = try await validAccessToken()
            var messages: [Int: GmailMessage] = [:]
            try await withThrowingTaskGroup(of: (Int, GmailMessage?).self) { group in
                for (index, identifier) in identifiers.enumerated() {
                    group.addTask {
                        let data = try await self.authorizedData(from: GmailAPI.messageURL(identifier: identifier, full: false))
                        return (index, GmailAPI.parseMessage(data))
                    }
                }
                for try await (index, message) in group {
                    if let message { messages[index] = message }
                }
            }
            return messages.keys.sorted().compactMap { messages[$0]?.summaryLine }.joined(separator: "\n")
        } catch {
            return "Gmail search failed: \(error.localizedDescription)"
        }
    }

    func readEmail(identifier: String) async -> String {
        do {
            guard let message = GmailAPI.parseMessage(try await authorizedData(from: GmailAPI.messageURL(identifier: identifier, full: true))) else {
                return "Could not read this email."
            }
            return GmailAPI.readableMessage(message)
        } catch {
            return "Could not read the email: \(error.localizedDescription)"
        }
    }

    // MARK: Drive

    func searchDrive(query: String) async -> String {
        do {
            let files = DriveAPI.parseFiles(try await authorizedData(from: DriveAPI.searchURL(query: query)))
            guard !files.isEmpty else { return "No Drive files match \"\(query)\"." }
            return files.map(\.summaryLine).joined(separator: "\n")
        } catch {
            return "Drive search failed: \(error.localizedDescription)"
        }
    }

    func readDriveFile(identifier: String) async -> String {
        do {
            guard let file = DriveAPI.parseFiles(try await authorizedData(from: DriveAPI.metadataURL(identifier: identifier))).first else {
                return "File not found."
            }
            if file.mimeType == "application/vnd.google-apps.folder" {
                return "This is a folder. Open it with open_url: \(file.webViewLink ?? "")"
            }
            let content = DriveAPI.contentURL(for: file)
            let data = try await authorizedData(from: content.url)
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("macky-drive-\(file.identifier)")
                .appendingPathExtension(content.isExport ? "txt" : (file.name as NSString).pathExtension)
            try data.write(to: temporaryURL)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let text = FileTextReader.readText(at: temporaryURL)
            return "\(file.name) (\(DriveAPI.kindName(for: file.mimeType))):\n\n\(text)"
        } catch {
            return "Could not read the Drive file: \(error.localizedDescription)"
        }
    }
}

/// Resumes a continuation at most once, whichever callback comes first.
private final class OneShotContinuation<Value>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pendingContinuation = continuation
        continuation = nil
        lock.unlock()
        pendingContinuation?.resume(with: result)
    }
}
