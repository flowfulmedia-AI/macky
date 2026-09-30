import Foundation
import MackyCore

/// One connected app: an MCP server reachable over HTTP (e.g. the user's Flowts app on Lovable).
struct MCPServerConfiguration: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var isEnabled = true
    /// Told to the model: what the app is for and when to use it.
    var instructions: String
    /// Header that carries the token, when the server needs one ("Authorization" sends "Bearer <token>").
    var authorizationHeaderName = "Authorization"
}

/// Talks to one MCP server with the Streamable HTTP transport: initialize once, then tools/list and tools/call.
@MainActor
final class MCPClient {
    private(set) var configuration: MCPServerConfiguration
    private let token: String?
    private let authorizer: MCPOAuthAuthorizer
    private var sessionIdentifier: String?
    private var isInitialized = false
    private var nextRequestIdentifier = 1
    private(set) var tools: [MCPToolDescriptor] = []
    private(set) var toolsLoadedAt: Date?
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        return URLSession(configuration: configuration)
    }()

    init(configuration: MCPServerConfiguration, token: String?, authorizer: MCPOAuthAuthorizer) {
        self.configuration = configuration
        self.token = token
        self.authorizer = authorizer
    }

    func loadTools() async throws -> [MCPToolDescriptor] {
        try await ensureInitialized()
        var allTools: [MCPToolDescriptor] = []
        var cursor: String?
        repeat {
            let result = try await request { MCPProtocol.listToolsRequest(identifier: $0, cursor: cursor) }
            let page = MCPProtocol.parseTools(fromResult: result)
            allTools += page.tools
            cursor = page.nextCursor
        } while cursor != nil && allTools.count < 200
        tools = allTools
        toolsLoadedAt = Date()
        return allTools
    }

    func callTool(named name: String, argumentsJSON: String) async throws -> (text: String, isError: Bool) {
        try await ensureInitialized()
        let result = try await request { MCPProtocol.callToolRequest(identifier: $0, name: name, argumentsJSON: argumentsJSON) }
        return MCPProtocol.toolResultText(fromResult: result)
    }

    private func ensureInitialized() async throws {
        guard !isInitialized else { return }
        sessionIdentifier = nil
        _ = try await request(allowsSessionRestart: false) { MCPProtocol.initializeRequest(identifier: $0) }
        isInitialized = true
        // A notification: the server answers 202 with no body.
        _ = try? await send(MCPProtocol.initializedNotification())
    }

    /// Sends a request and returns its result. A server that forgot the session (404) gets a fresh one, once.
    private func request(allowsSessionRestart: Bool = true, allowsTokenRefresh: Bool = true, _ makeBody: (Int) -> Data) async throws -> [String: Any] {
        let identifier = nextRequestIdentifier
        nextRequestIdentifier += 1
        let (data, response) = try await send(makeBody(identifier))
        if response.statusCode == 401, allowsTokenRefresh, authorizer.isSignedIn, await authorizer.refresh() {
            return try await request(allowsSessionRestart: allowsSessionRestart, allowsTokenRefresh: false, makeBody)
        }
        if response.statusCode == 404, allowsSessionRestart, sessionIdentifier != nil {
            isInitialized = false
            try await ensureInitialized()
            return try await request(allowsSessionRestart: false, makeBody)
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw MCPAuthorizationRequired(serverName: configuration.name, wwwAuthenticateHeader: response.value(forHTTPHeaderField: "WWW-Authenticate"))
        default:
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            throw MCPProtocol.RPCError(message: "\(configuration.name) a răspuns HTTP \(response.statusCode). \(detail)")
        }
        if let newSessionIdentifier = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !newSessionIdentifier.isEmpty {
            sessionIdentifier = newSessionIdentifier
        }
        return try MCPProtocol.response(withIdentifier: identifier, in: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
    }

    private func send(_ body: Data) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: configuration.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MCPProtocol.RPCError(message: "Adresa serverului \(configuration.name) nu e validă.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if isInitialized { request.setValue(MCPProtocol.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionIdentifier { request.setValue(sessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id") }
        if let accessToken = await authorizer.accessToken() {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        } else if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            let headerName = configuration.authorizationHeaderName.isEmpty ? "Authorization" : configuration.authorizationHeaderName
            let needsBearerPrefix = headerName.lowercased() == "authorization" && !token.lowercased().hasPrefix("bearer ")
            request.setValue(needsBearerPrefix ? "Bearer \(token)" : token, forHTTPHeaderField: headerName)
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPProtocol.RPCError(message: "Răspuns invalid de la \(configuration.name).")
        }
        return (data, httpResponse)
    }
}

/// The server wants the user to sign in (OAuth) or a token.
struct MCPAuthorizationRequired: LocalizedError {
    var serverName: String
    var wwwAuthenticateHeader: String?
    var errorDescription: String? { "\(serverName) cere autentificare: apasă „Conectează (login)”." }
}

/// The user's connected apps, their tokens (in the Keychain) and their tools, ready to offer to the model.
@MainActor
final class MCPConnectionStore: ObservableObject {
    private static let keychainService = "com.flowfulmedia.macky.mcp"
    private static let defaultsKey = "mcpServers"
    /// Tools are re-read in the background after this long, so changes in the app show up by themselves.
    private static let toolsRefreshInterval: TimeInterval = 10 * 60

    @Published private(set) var servers: [MCPServerConfiguration] = []
    @Published private(set) var statusByServer: [UUID: String] = [:]
    @Published private(set) var toolNamesByServer: [UUID: [String]] = [:]
    /// Servers that answered "sign in first", with the header that says where.
    @Published private(set) var loginRequiredByServer: [UUID: String] = [:]
    @Published private(set) var signingInServers: Set<UUID> = []
    private var signInAttempts: [UUID: UUID] = [:]
    private var authorizers: [UUID: MCPOAuthAuthorizer] = [:]

    private var clients: [UUID: MCPClient] = [:]
    private var refreshingServers: Set<UUID> = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let savedServers = try? JSONDecoder().decode([MCPServerConfiguration].self, from: data) {
            servers = savedServers
        } else {
            // The user's own task and notes app.
            servers = [MCPServerConfiguration(
                name: "Flowts",
                url: "https://flowts.lovable.app/mcp",
                instructions: "Aplicația mea de taskuri și notițe. Folosește-o pentru taskurile și notițele mele (în loc de Reminders și Notes), dacă nu spun altă aplicație."
            )]
            save()
        }
    }

    // MARK: Editing

    func upsert(_ server: MCPServerConfiguration) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        clients[server.id] = nil
        save()
    }

    func delete(_ identifier: UUID) {
        servers.removeAll { $0.id == identifier }
        clients[identifier] = nil
        KeychainStore.delete(service: Self.keychainService, account: identifier.uuidString)
        authorizer(for: identifier).signOut()
        authorizers[identifier] = nil
        statusByServer[identifier] = nil
        toolNamesByServer[identifier] = nil
        save()
    }

    func hasToken(for identifier: UUID) -> Bool {
        !(KeychainStore.readString(service: Self.keychainService, account: identifier.uuidString) ?? "").isEmpty
    }

    func saveToken(_ token: String, for identifier: UUID) throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            KeychainStore.delete(service: Self.keychainService, account: identifier.uuidString)
        } else {
            try KeychainStore.writeString(trimmedToken, service: Self.keychainService, account: identifier.uuidString)
        }
        clients[identifier] = nil
        objectWillChange.send()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Tools

    private func authorizer(for identifier: UUID) -> MCPOAuthAuthorizer {
        if let authorizer = authorizers[identifier] { return authorizer }
        let authorizer = MCPOAuthAuthorizer(serverIdentifier: identifier)
        authorizers[identifier] = authorizer
        return authorizer
    }

    func isSignedIn(_ identifier: UUID) -> Bool {
        authorizer(for: identifier).isSignedIn
    }

    /// Opens the browser to approve Macky, then loads the tools.
    func signIn(_ identifier: UUID) async {
        guard let server = servers.first(where: { $0.id == identifier }),
              let mcpURL = URL(string: server.url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let attempt = UUID()
        signInAttempts[identifier] = attempt
        signingInServers.insert(identifier)
        statusByServer[identifier] = "Aprobă accesul în browser… (dacă după login nu apare „Macky e conectat”, apasă din nou Conectează)"
        do {
            try await authorizer(for: identifier).signIn(mcpURL: mcpURL, wwwAuthenticateHeader: loginRequiredByServer[identifier])
            guard signInAttempts[identifier] == attempt else { return }
            signingInServers.remove(identifier)
            loginRequiredByServer[identifier] = nil
            clients[identifier] = nil
            await refreshTools(for: identifier)
        } catch {
            // A newer attempt replaced this one: it reports its own result.
            guard signInAttempts[identifier] == attempt else { return }
            signingInServers.remove(identifier)
            statusByServer[identifier] = "Login eșuat: \(error.localizedDescription)"
        }
    }

    func signOut(_ identifier: UUID) {
        authorizer(for: identifier).signOut()
        clients[identifier] = nil
        toolNamesByServer[identifier] = nil
        statusByServer[identifier] = "Deconectat."
        objectWillChange.send()
    }

    private func client(for server: MCPServerConfiguration) -> MCPClient {
        if let client = clients[server.id], client.configuration == server { return client }
        let client = MCPClient(configuration: server, token: KeychainStore.readString(service: Self.keychainService, account: server.id.uuidString),
                               authorizer: authorizer(for: server.id))
        clients[server.id] = client
        return client
    }

    /// Connects and reads the server's tools; also the "Testează" button.
    func refreshTools(for identifier: UUID) async {
        guard let server = servers.first(where: { $0.id == identifier }), !refreshingServers.contains(identifier) else { return }
        refreshingServers.insert(identifier)
        defer { refreshingServers.remove(identifier) }
        statusByServer[identifier] = "Se conectează…"
        do {
            let tools = try await client(for: server).loadTools()
            toolNamesByServer[identifier] = tools.map(\.name)
            loginRequiredByServer[identifier] = nil
            statusByServer[identifier] = tools.isEmpty ? "Conectat, dar serverul nu are unelte." : "Conectat · \(tools.count) unelte"
        } catch let authorizationRequired as MCPAuthorizationRequired {
            loginRequiredByServer[identifier] = authorizationRequired.wwwAuthenticateHeader ?? ""
            statusByServer[identifier] = "Cere login: apasă „Conectează (login)”."
        } catch {
            statusByServer[identifier] = "Eroare: \(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        for server in servers where server.isEnabled {
            await refreshTools(for: server.id)
        }
    }

    /// Tools for the next model request. Uses what is already loaded; loads (briefly waiting) only the first time,
    /// and refreshes stale lists in the background so a request is never slowed down by it.
    func toolsForRequest() async -> [(server: MCPServerConfiguration, tool: MCPToolDescriptor)] {
        var result: [(MCPServerConfiguration, MCPToolDescriptor)] = []
        for server in servers where server.isEnabled {
            let client = client(for: server)
            if client.toolsLoadedAt == nil {
                // Wait at most 4 s; a slow server just misses this request and is ready for the next.
                Task { await self.refreshTools(for: server.id) }
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if client.toolsLoadedAt != nil || !refreshingServers.contains(server.id) { break }
                }
            } else if let loadedAt = client.toolsLoadedAt, Date().timeIntervalSince(loadedAt) > Self.toolsRefreshInterval {
                Task { await self.refreshTools(for: server.id) }
            }
            result += client.tools.map { (server, $0) }
        }
        return result
    }

    /// Recognizes a model tool call that belongs to a connected app.
    func action(for toolCall: ChatToolCall) -> ScreenAction? {
        guard toolCall.name.hasPrefix(MCPToolNaming.prefix) else { return nil }
        for server in servers where server.isEnabled {
            guard let client = clients[server.id] else { continue }
            if let tool = client.tools.first(where: { MCPToolNaming.modelToolName(serverName: server.name, toolName: $0.name) == toolCall.name }) {
                return .externalTool(serverName: server.name, toolName: tool.name, argumentsJSON: toolCall.argumentsJSON, needsConfirmation: tool.needsConfirmation)
            }
        }
        return nil
    }

    func callTool(serverName: String, toolName: String, argumentsJSON: String) async -> (text: String, isError: Bool) {
        guard let server = servers.first(where: { $0.name == serverName && $0.isEnabled }) else {
            return ("\(serverName) is not connected.", true)
        }
        do {
            return try await client(for: server).callTool(named: toolName, argumentsJSON: argumentsJSON)
        } catch {
            return (error.localizedDescription, true)
        }
    }
}
