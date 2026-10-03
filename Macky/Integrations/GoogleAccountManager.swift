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

    /// The full Drive permission (saving into the user's folders) arrived with the latest sign-in.
    @Published private(set) var canWriteToDriveFolders = GoogleOAuth.grantsDriveWrite(UserDefaults.standard.string(forKey: GoogleAccountManager.grantedScopeDefaultsKey))
    static let grantedScopeDefaultsKey = "googleGrantedScope"
    @Published private(set) var hasClientCredentials: Bool
    @Published private(set) var isConnected: Bool
    @Published private(set) var connectedEmailAddress: String?
    @Published private(set) var statusText: String?
    @Published private(set) var isConnecting = false
    /// More Gmail accounts, read-only, searched together with the main one. Drive and agents use the main account.
    @Published private(set) var additionalGmailAddresses: [String] = UserDefaults.standard.stringArray(forKey: "googleAdditionalAccounts") ?? []
    private var additionalAccessTokens: [String: (token: String, expiry: Date)] = [:]

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
        guard let tokens = await authorize() else { return }
        guard let newRefreshToken = tokens.refreshToken else {
            statusText = "Google nu a trimis un refresh token. Deconectează Macky din contul Google și încearcă din nou."
            return
        }
        do {
            try KeychainStore.writeString(newRefreshToken, service: Self.keychainService, account: "refresh-token")
        } catch {
            statusText = "Conectarea a eșuat: \(error.localizedDescription)"
            return
        }
        refreshToken = newRefreshToken
        accessToken = tokens.accessToken
        accessTokenExpiryDate = Date().addingTimeInterval(tokens.expiresInSeconds - 60)
        UserDefaults.standard.set(tokens.grantedScope, forKey: Self.grantedScopeDefaultsKey)
        canWriteToDriveFolders = GoogleOAuth.grantsDriveWrite(tokens.grantedScope)
        isConnected = true
        await loadProfile()
        statusText = "Conectat" + (connectedEmailAddress.map { " ca \($0)" } ?? "") + "."
    }

    /// Adds another Gmail account (pick it in Google's account chooser). Its mail is searched together with the main account's.
    func connectAdditionalGmail() async {
        guard let tokens = await authorize() else { return }
        guard let newRefreshToken = tokens.refreshToken else {
            statusText = "Google nu a trimis un refresh token. Încearcă din nou."
            return
        }
        guard let emailAddress = await emailAddress(accessToken: tokens.accessToken) else {
            statusText = "Nu am putut citi adresa contului adăugat."
            return
        }
        if emailAddress.lowercased() == connectedEmailAddress?.lowercased() {
            statusText = "\(emailAddress) e deja contul principal. Alege alt cont în fereastra Google."
            return
        }
        do {
            try KeychainStore.writeString(newRefreshToken, service: Self.keychainService, account: "refresh-token|" + emailAddress.lowercased())
        } catch {
            statusText = "Nu am putut salva contul: \(error.localizedDescription)"
            return
        }
        additionalAccessTokens[emailAddress.lowercased()] = (tokens.accessToken, Date().addingTimeInterval(tokens.expiresInSeconds - 60))
        if !additionalGmailAddresses.contains(where: { $0.lowercased() == emailAddress.lowercased() }) {
            additionalGmailAddresses.append(emailAddress)
            UserDefaults.standard.set(additionalGmailAddresses, forKey: "googleAdditionalAccounts")
        }
        statusText = "Am adăugat \(emailAddress)."
    }

    func removeAdditionalGmail(_ emailAddress: String) {
        KeychainStore.delete(service: Self.keychainService, account: "refresh-token|" + emailAddress.lowercased())
        additionalAccessTokens[emailAddress.lowercased()] = nil
        additionalGmailAddresses.removeAll { $0.lowercased() == emailAddress.lowercased() }
        UserDefaults.standard.set(additionalGmailAddresses, forKey: "googleAdditionalAccounts")
    }

    /// The browser sign-in; returns the tokens, or nil after showing why it did not work.
    private func authorize() async -> GoogleOAuth.Tokens? {
        guard let clientIdentifier, let clientSecret, hasClientCredentials else {
            statusText = "Adaugă întâi Client ID și Client secret."
            return nil
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
                return nil
            }
            guard callback.state == state, let code = callback.code else {
                statusText = "Răspuns neașteptat de la Google. Încearcă din nou."
                return nil
            }
            var request = URLRequest(url: GoogleOAuth.tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = GoogleOAuth.authorizationCodeRequestBody(code: code, clientIdentifier: clientIdentifier, clientSecret: clientSecret,
                                                                          redirectURI: redirectURI, codeVerifier: codeVerifier)
            let (data, _) = try await urlSession.data(for: request)
            return try GoogleOAuth.parseTokenResponse(data)
        } catch {
            statusText = "Conectarea a eșuat: \(error.localizedDescription)"
            return nil
        }
    }

    private func emailAddress(accessToken: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await urlSession.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["emailAddress"] as? String
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

    /// `account` nil = the main account; otherwise one of the additional Gmail addresses.
    private func validAccessToken(account: String? = nil) async throws -> String {
        if let account { return try await additionalAccessToken(for: account.lowercased()) }
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

    private func additionalAccessToken(for account: String) async throws -> String {
        if let cached = additionalAccessTokens[account], Date() < cached.expiry { return cached.token }
        guard let refreshToken = KeychainStore.readString(service: Self.keychainService, account: "refresh-token|" + account),
              let clientIdentifier, let clientSecret else {
            throw GoogleOAuth.OAuthError(message: "Contul \(account) nu mai e conectat. Adaugă-l din nou în Setări → Conexiuni → Email și Drive.")
        }
        var request = URLRequest(url: GoogleOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleOAuth.refreshRequestBody(refreshToken: refreshToken, clientIdentifier: clientIdentifier, clientSecret: clientSecret)
        let (data, _) = try await urlSession.data(for: request)
        let tokens = try GoogleOAuth.parseTokenResponse(data)
        additionalAccessTokens[account] = (tokens.accessToken, Date().addingTimeInterval(tokens.expiresInSeconds - 60))
        return tokens.accessToken
    }

    private func authorizedData(from url: URL, allowRetry: Bool = true, account: String? = nil) async throws -> Data {
        try await authorizedData(for: URLRequest(url: url), allowRetry: allowRetry, account: account)
    }

    private func authorizedData(for originalRequest: URLRequest, allowRetry: Bool = true, account: String? = nil) async throws -> Data {
        var request = originalRequest
        request.setValue("Bearer \(try await validAccessToken(account: account))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode == 401 && allowRetry {
            if let account { additionalAccessTokens[account.lowercased()] = nil } else { accessToken = nil }
            return try await authorizedData(for: originalRequest, allowRetry: false, account: account)
        }
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "HTTP \(statusCode)"
            if statusCode == 403 && message.lowercased().contains("insufficient") {
                throw GoogleOAuth.OAuthError(message: "Google nu i-a dat lui Macky voie să salveze în Drive. Apasă Deconectează, apoi Conectează Google din nou în Setări → Conexiuni.")
            }
            throw GoogleOAuth.OAuthError(message: "Google: \(message)")
        }
        return data
    }

    // MARK: Drive upload

    /// Saves an HTML document as a Google Doc in a folder Macky creates (and remembers). Returns the doc's link.
    func uploadGoogleDoc(named name: String, html: String, folderName: String) async throws -> String {
        let folderIdentifier = try await folderIdentifier(named: folderName)
        let upload = DriveUpload.multipartBody(name: name, targetMimeType: "application/vnd.google-apps.document",
                                               parentFolderIdentifier: folderIdentifier, content: Data(html.utf8), contentMimeType: "text/html")
        var request = URLRequest(url: DriveUpload.uploadURL)
        request.httpMethod = "POST"
        request.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = upload.body
        guard let created = DriveUpload.parseCreatedFile(try await authorizedData(for: request)) else {
            throw GoogleOAuth.OAuthError(message: "Drive nu a confirmat documentul.")
        }
        return created.link ?? "https://docs.google.com/document/d/\(created.identifier)"
    }

    /// Saves a Google Doc into one of the user's own folders (needs the full Drive permission).
    func uploadGoogleDoc(named name: String, html: String, intoFolder folderIdentifier: String) async throws -> String {
        let upload = DriveUpload.multipartBody(name: name, targetMimeType: "application/vnd.google-apps.document",
                                               parentFolderIdentifier: folderIdentifier, content: Data(html.utf8), contentMimeType: "text/html")
        var request = URLRequest(url: DriveUpload.uploadURL)
        request.httpMethod = "POST"
        request.setValue(upload.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = upload.body
        do {
            guard let created = DriveUpload.parseCreatedFile(try await authorizedData(for: request)) else {
                throw GoogleOAuth.OAuthError(message: "Drive nu a confirmat documentul.")
            }
            return created.link ?? "https://docs.google.com/document/d/\(created.identifier)"
        } catch let error as GoogleOAuth.OAuthError where error.message.lowercased().contains("not found") || error.message.lowercased().contains("insufficient") {
            throw GoogleOAuth.OAuthError(message: canWriteToDriveFolders
                ? "Nu găsesc folderul din Drive. Verifică linkul folderului în setările agentului."
                : "Macky nu are încă voie să scrie în folderele tale din Drive. Setări → Conexiuni → Email și Drive → Deconectează, apoi Conectează din nou.")
        }
    }

    private func folderIdentifier(named folderName: String) async throws -> String {
        let defaultsKey = "googleDriveFolder|" + folderName
        if let savedIdentifier = UserDefaults.standard.string(forKey: defaultsKey),
           let data = try? await authorizedData(from: DriveAPI.metadataURL(identifier: savedIdentifier)),
           !DriveAPI.parseFiles(data).isEmpty {
            return savedIdentifier
        }
        var request = URLRequest(url: DriveUpload.filesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = DriveUpload.folderMetadata(name: folderName)
        guard let created = DriveUpload.parseCreatedFile(try await authorizedData(for: request)) else {
            throw GoogleOAuth.OAuthError(message: "Nu am putut crea folderul „\(folderName)” în Drive.")
        }
        UserDefaults.standard.set(created.identifier, forKey: defaultsKey)
        return created.identifier
    }

    // MARK: Gmail

    /// Every connected Gmail account (or only the one matching `accountFilter`); one line per email.
    func searchGmailLines(query: String, maximumResults: Int, accountFilter: String?) async -> [String] {
        let wanted = accountFilter?.lowercased()
        var accounts: [String?] = []
        if isConnected, wanted.map({ (connectedEmailAddress ?? "").lowercased().contains($0) }) ?? true { accounts.append(nil) }
        accounts += additionalGmailAddresses.filter { address in wanted.map { address.lowercased().contains($0) } ?? true }.map { Optional($0) }
        var lines: [String] = []
        for account in accounts {
            let label = account ?? connectedEmailAddress ?? "Gmail"
            do {
                let messages = try await searchMessages(query: query, maximumResults: maximumResults, account: account)
                lines += messages.map { message in
                    let identifier = account.map { "gmail:\($0.lowercased())#\(message.identifier)" } ?? message.identifier
                    var line = message.summaryLine.replacingOccurrences(of: "id=\(message.identifier)", with: "id=\(identifier)")
                    if !additionalGmailAddresses.isEmpty { line = line.replacingOccurrences(of: "id=\(identifier) |", with: "id=\(identifier) | account: \(label) |") }
                    return line
                }
            } catch {
                lines.append("\(label): Gmail search failed (\(error.localizedDescription))")
            }
        }
        return lines
    }

    func searchGmail(query: String, maximumResults: Int) async -> String {
        let lines = await searchGmailLines(query: query, maximumResults: maximumResults, accountFilter: nil)
        return lines.isEmpty ? "No emails match \"\(query)\"." : lines.joined(separator: "\n")
    }

    private func searchMessages(query: String, maximumResults: Int, account: String?) async throws -> [GmailMessage] {
        let identifiers = GmailAPI.parseMessageIdentifiers(try await authorizedData(from: GmailAPI.searchURL(query: query, maximumResults: maximumResults), account: account))
        guard !identifiers.isEmpty else { return [] }
        // One token refresh up front, not one per parallel request.
        _ = try await validAccessToken(account: account)
        var messages: [Int: GmailMessage] = [:]
        try await withThrowingTaskGroup(of: (Int, GmailMessage?).self) { group in
            for (index, identifier) in identifiers.enumerated() {
                group.addTask {
                    let data = try await self.authorizedData(from: GmailAPI.messageURL(identifier: identifier, full: false), account: account)
                    return (index, GmailAPI.parseMessage(data))
                }
            }
            for try await (index, message) in group {
                if let message { messages[index] = message }
            }
        }
        return messages.keys.sorted().compactMap { messages[$0] }
    }

    /// Reads one email by the id from a search ("gmail:ana@gmail.com#18c…" for additional accounts).
    func readEmail(identifier: String) async -> String {
        var account: String?
        var messageIdentifier = identifier
        if identifier.hasPrefix("gmail:"), let hash = identifier.lastIndex(of: "#") {
            account = String(identifier[identifier.index(identifier.startIndex, offsetBy: 6)..<hash])
            messageIdentifier = String(identifier[identifier.index(after: hash)...])
        }
        do {
            guard let message = GmailAPI.parseMessage(try await authorizedData(from: GmailAPI.messageURL(identifier: messageIdentifier, full: true), account: account)) else {
                return "Could not read this email."
            }
            return (account.map { "Account: \($0)\n" } ?? "") + GmailAPI.readableMessage(message)
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
