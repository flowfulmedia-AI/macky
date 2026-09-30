import AppKit
import CryptoKit
import Foundation
import MackyCore
import Network

/// Signs Macky in to an MCP server that uses OAuth (like Flowts): discovers the authorization server,
/// registers Macky as a client, opens the browser once for approval, then keeps the tokens fresh.
/// Tokens are stored in the Keychain.
@MainActor
final class MCPOAuthAuthorizer {
    private static let keychainService = "com.flowfulmedia.macky.mcp"
    private let serverIdentifier: UUID
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
    private(set) var credentials: MCPOAuth.StoredCredentials?

    init(serverIdentifier: UUID) {
        self.serverIdentifier = serverIdentifier
        if let text = KeychainStore.readString(service: Self.keychainService, account: keychainAccount),
           let data = text.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            credentials = try? decoder.decode(MCPOAuth.StoredCredentials.self, from: data)
        }
    }

    private var keychainAccount: String { "\(serverIdentifier.uuidString)-oauth" }
    var isSignedIn: Bool { credentials != nil }

    /// A valid access token, refreshed when it expired; nil when never signed in.
    func accessToken() async -> String? {
        guard let credentials else { return nil }
        if credentials.isExpired(), credentials.refreshToken != nil {
            _ = await refresh()
        }
        return self.credentials?.accessToken
    }

    /// After a 401: tries the refresh token. Returns whether a new token is available.
    func refresh() async -> Bool {
        guard let credentials, let refreshToken = credentials.refreshToken, let tokenURL = URL(string: credentials.tokenEndpoint) else { return false }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = MCPOAuth.refreshRequestBody(clientIdentifier: credentials.clientIdentifier, refreshToken: refreshToken)
        guard let (data, response) = try? await urlSession.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let tokens = try? GoogleOAuth.parseTokenResponse(data) else { return false }
        save(credentials.updated(with: tokens))
        return true
    }

    func signOut() {
        credentials = nil
        KeychainStore.delete(service: Self.keychainService, account: keychainAccount)
    }

    /// The full sign-in: discovery → client registration → browser approval → tokens.
    func signIn(mcpURL: URL, wwwAuthenticateHeader: String?) async throws {
        let metadata = try await discoverAuthorizationServer(mcpURL: mcpURL, wwwAuthenticateHeader: wwwAuthenticateHeader)
        let receiver = try await LoopbackOAuthReceiver.start()
        defer { receiver.stop() }
        let redirectURI = "http://localhost:\(receiver.port)/callback"

        guard let registrationEndpoint = metadata.registrationEndpoint.flatMap(URL.init(string:)) else {
            throw MCPProtocol.RPCError(message: "Serverul nu permite înregistrarea automată a lui Macky ca aplicație.")
        }
        var registration = URLRequest(url: registrationEndpoint)
        registration.httpMethod = "POST"
        registration.setValue("application/json", forHTTPHeaderField: "Content-Type")
        registration.httpBody = MCPOAuth.registrationRequestBody(redirectURI: redirectURI)
        let (registrationData, registrationResponse) = try await urlSession.data(for: registration)
        guard (registrationResponse as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let clientIdentifier = MCPOAuth.parseClientIdentifier(fromRegistrationResponse: registrationData) else {
            throw MCPProtocol.RPCError(message: "Înregistrarea lui Macky la server a eșuat (HTTP \((registrationResponse as? HTTPURLResponse)?.statusCode ?? 0)).")
        }

        let codeVerifier = GoogleOAuth.makeCodeVerifier()
        let codeChallenge = GoogleOAuth.base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        let state = UUID().uuidString
        guard let authorizationURL = MCPOAuth.authorizationURL(metadata: metadata, clientIdentifier: clientIdentifier, redirectURI: redirectURI,
                                                               codeChallenge: codeChallenge, state: state) else {
            throw MCPProtocol.RPCError(message: "Adresa de autorizare a serverului nu e validă.")
        }
        NSWorkspace.shared.open(authorizationURL)

        let callback = try await receiver.waitForCallback()
        if let error = callback.error {
            throw MCPProtocol.RPCError(message: error == "access_denied" ? "Accesul a fost refuzat." : "Serverul a răspuns cu eroarea: \(error)")
        }
        guard callback.state == state, let code = callback.code, let tokenURL = URL(string: metadata.tokenEndpoint) else {
            throw MCPProtocol.RPCError(message: "Răspuns neașteptat la login. Încearcă din nou.")
        }
        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        tokenRequest.httpBody = MCPOAuth.authorizationCodeRequestBody(code: code, clientIdentifier: clientIdentifier, redirectURI: redirectURI, codeVerifier: codeVerifier)
        let (tokenData, _) = try await urlSession.data(for: tokenRequest)
        let tokens = try GoogleOAuth.parseTokenResponse(tokenData)
        save(MCPOAuth.StoredCredentials(
            clientIdentifier: clientIdentifier, tokenEndpoint: metadata.tokenEndpoint, accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken, expiresAt: Date().addingTimeInterval(tokens.expiresInSeconds)
        ))
    }

    private func discoverAuthorizationServer(mcpURL: URL, wwwAuthenticateHeader: String?) async throws -> MCPOAuth.AuthorizationServerMetadata {
        var issuer: String?
        for url in MCPOAuth.protectedResourceMetadataURLs(mcpURL: mcpURL, wwwAuthenticateHeader: wwwAuthenticateHeader) {
            if let (data, response) = try? await urlSession.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let server = MCPOAuth.authorizationServer(fromProtectedResourceMetadata: data) {
                issuer = server
                break
            }
        }
        // Servers without protected resource metadata may host the authorization server themselves.
        let candidates = MCPOAuth.authorizationServerMetadataURLs(issuer: issuer ?? MCPOAuth.origin(of: mcpURL) ?? mcpURL.absoluteString)
        for url in candidates {
            if let (data, response) = try? await urlSession.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let metadata = MCPOAuth.parseAuthorizationServerMetadata(data) {
                return metadata
            }
        }
        throw MCPProtocol.RPCError(message: "Nu am găsit serverul de autorizare. Serverul MCP nu publică metadatele OAuth.")
    }

    private func save(_ newCredentials: MCPOAuth.StoredCredentials) {
        credentials = newCredentials
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(newCredentials) {
            try? KeychainStore.writeString(String(decoding: data, as: UTF8.self), service: Self.keychainService, account: keychainAccount)
        }
    }
}

/// A tiny local web server that receives the browser's redirect after the user approves (http://localhost:PORT/callback).
/// It listens on all loopback addresses ("localhost" may resolve to IPv4 or IPv6) and refuses other machines.
final class LoopbackOAuthReceiver: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GoogleOAuth.AuthorizationCallback, Error>?
    private var receivedCallback: GoogleOAuth.AuthorizationCallback?

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LoopbackOAuthReceiver {
        let listener = try NWListener(using: .tcp)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumeOnce = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: resumeOnce.resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): resumeOnce.resume(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: .main)
        }
        let receiver = LoopbackOAuthReceiver(listener: listener, port: port)
        listener.newConnectionHandler = { [weak receiver] connection in receiver?.handle(connection) }
        return receiver
    }

    func stop() {
        listener.cancel()
        finish(.failure(CancellationError()))
    }

    /// Waits up to 5 minutes for the redirect.
    func waitForCallback() async throws -> GoogleOAuth.AuthorizationCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let receivedCallback {
                lock.unlock()
                continuation.resume(returning: receivedCallback)
                return
            }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
                self?.finish(.failure(MCPProtocol.RPCError(message: "Timpul a expirat: nu ai aprobat în 5 minute.")))
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let requestText = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let callback = GoogleOAuth.parseCallback(requestText: requestText)
            let page = callback == nil
                ? "<html><body></body></html>"
                : "<html><head><meta charset='utf-8'></head><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>Macky e conectat.</h2><p>Poți închide această filă.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let callback { self?.finish(.success(callback)) }
        }
    }

    private func finish(_ result: Result<GoogleOAuth.AuthorizationCallback, Error>) {
        lock.lock()
        let pendingContinuation = continuation
        continuation = nil
        if case .success(let callback) = result, pendingContinuation == nil, receivedCallback == nil {
            receivedCallback = callback
        }
        lock.unlock()
        pendingContinuation?.resume(with: result)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || "\(address)".hasSuffix("127.0.0.1")
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}

private final class ResumeOnce<Value>: @unchecked Sendable {
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
