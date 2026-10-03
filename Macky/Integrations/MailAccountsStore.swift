import Foundation
import MackyCore
import Network

/// Email accounts other than Gmail (Yahoo, iCloud, Outlook…), read over IMAP with an app password.
/// The list lives in UserDefaults, passwords in Macky's secrets file. Read-only: the inbox is opened with EXAMINE.
@MainActor
final class MailAccountsStore: ObservableObject {
    @Published private(set) var accounts: [IMAPAccount] = []
    @Published var statusText: String?
    @Published private(set) var isWorking = false

    private static let defaultsKey = "imapAccounts"
    private static let secretsService = "com.flowfulmedia.macky.imap"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([IMAPAccount].self, from: data) {
            accounts = saved
        }
    }

    var hasAccounts: Bool { !accounts.isEmpty }

    /// Checks the login first; only a working account is saved.
    func add(emailAddress: String, password: String, host: String, port: Int = 993) async {
        let email = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password.replacingOccurrences(of: " ", with: "")
        let server = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !secret.isEmpty, !server.isEmpty else {
            statusText = "✗ Completează adresa, parola de aplicație și serverul."
            return
        }
        isWorking = true
        statusText = "Verific contul…"
        defer { isWorking = false }
        let account = IMAPAccount(emailAddress: email, host: server, port: port)
        do {
            let session = try await IMAPSession.open(account: account, password: secret)
            await session.logout()
            try KeychainStore.writeString(secret, service: Self.secretsService, account: account.id)
            accounts.removeAll { $0.id == account.id }
            accounts.append(account)
            save()
            statusText = "Conectat: \(email)."
        } catch {
            statusText = "✗ \(error.localizedDescription)"
            ErrorLogStore.shared.record("Email \(email)", error.localizedDescription)
        }
    }

    func remove(_ account: IMAPAccount) {
        KeychainStore.delete(service: Self.secretsService, account: account.id)
        accounts.removeAll { $0.id == account.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Reading

    /// The latest matching messages of every account (or only `accountFilter`), one line each.
    func search(query: String, maximumResults: Int, accountFilter: String?) async -> [String] {
        let wanted = accountFilter?.lowercased()
        var lines: [String] = []
        for account in accounts where wanted.map({ account.id.contains($0) }) ?? true {
            guard let password = KeychainStore.readString(service: Self.secretsService, account: account.id) else { continue }
            do {
                let session = try await IMAPSession.open(account: account, password: password)
                let messages = try await session.search(criteria: IMAPKit.searchCriteria(fromGmailQuery: Self.asciiFolded(query)), limit: maximumResults)
                await session.logout()
                lines += messages.map { message in
                    "id=imap:\(account.id)#\(message.uid) | account: \(account.emailAddress) | \(message.date) | from: \(message.from) | subject: \(message.subject)\(message.isUnread ? " | UNREAD" : "")"
                }
            } catch {
                lines.append("\(account.emailAddress): search failed (\(error.localizedDescription))")
                ErrorLogStore.shared.record("Email \(account.emailAddress)", "Căutarea a eșuat: \(error.localizedDescription)")
            }
        }
        return lines
    }

    /// Reads one message by the id from `search` ("imap:ana@yahoo.com#123").
    func read(identifier: String) async -> String {
        let reference = identifier.dropFirst("imap:".count)
        guard let hash = reference.lastIndex(of: "#"), let uid = Int(reference[reference.index(after: hash)...]),
              let account = accounts.first(where: { $0.id == reference[..<hash].lowercased() }),
              let password = KeychainStore.readString(service: Self.secretsService, account: account.id) else {
            return "This email account is not connected anymore."
        }
        do {
            let session = try await IMAPSession.open(account: account, password: password)
            let message = try await session.fetchFull(uid: uid)
            await session.logout()
            guard let message else { return "Email not found." }
            return "Account: \(account.emailAddress)\nFrom: \(message.from)\nDate: \(message.date)\nSubject: \(message.subject)\n\n\(message.bodyText)"
        } catch {
            ErrorLogStore.shared.record("Email \(account.emailAddress)", "Nu am putut citi emailul: \(error.localizedDescription)")
            return "Could not read the email: \(error.localizedDescription)"
        }
    }

    /// IMAP servers search reliably only in ASCII; "factură" finds "factura" and most real spellings.
    private static func asciiFolded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "ro"))
    }
}

/// One IMAP conversation over TLS: login, open the inbox read-only, search, fetch, log out.
final class IMAPSession: @unchecked Sendable {
    struct IMAPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "macky.imap")
    private var buffer = Data()
    private var tagNumber = 0

    private init(account: IMAPAccount) {
        connection = NWConnection(host: NWEndpoint.Host(account.host), port: NWEndpoint.Port(integerLiteral: UInt16(account.port)), using: .tls)
    }

    static func open(account: IMAPAccount, password: String) async throws -> IMAPSession {
        let session = IMAPSession(account: account)
        try await session.start()
        _ = try await session.readUntil { responses in responses.contains { $0.text.hasPrefix("* OK") || $0.text.hasPrefix("* PREAUTH") } }
        do {
            _ = try await session.run("LOGIN \(IMAPKit.quoted(account.emailAddress)) \(IMAPKit.quoted(password))")
        } catch {
            session.connection.cancel()
            throw IMAPError(message: "\(account.emailAddress): autentificarea a eșuat. Verifică adresa și folosește o parolă de aplicație, nu parola obișnuită.")
        }
        _ = try await session.run("EXAMINE INBOX")
        return session
    }

    /// The newest `limit` messages matching, newest first, with headers only.
    func search(criteria: String, limit: Int) async throws -> [IMAPMessage] {
        let uids = IMAPKit.searchResults(in: try await run("UID SEARCH \(criteria)")).sorted().suffix(limit)
        guard !uids.isEmpty else { return [] }
        let responses = try await run("UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])")
        return IMAPKit.fetchedItems(in: responses).map(IMAPKit.message(from:)).sorted { $0.uid > $1.uid }
    }

    func fetchFull(uid: Int) async throws -> IMAPMessage? {
        let responses = try await run("UID FETCH \(uid) (UID FLAGS BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.120000>)")
        return IMAPKit.fetchedItems(in: responses).first.map(IMAPKit.message(from:))
    }

    func logout() async {
        _ = try? await run("LOGOUT")
        connection.cancel()
    }

    // MARK: Protocol

    private func run(_ command: String) async throws -> [IMAPKit.Response] {
        tagNumber += 1
        let tag = "m\(tagNumber)"
        try await send(tag + " " + command + "\r\n")
        let responses = try await readUntil { IMAPKit.completion(of: tag, in: $0) != nil }
        guard let completion = IMAPKit.completion(of: tag, in: responses), completion.ok else {
            throw IMAPError(message: IMAPKit.completion(of: tag, in: responses)?.text ?? "Serverul a refuzat comanda.")
        }
        return responses
    }

    private func readUntil(_ isComplete: ([IMAPKit.Response]) -> Bool) async throws -> [IMAPKit.Response] {
        var collected: [IMAPKit.Response] = []
        let deadline = Date().addingTimeInterval(25)
        while true {
            let (responses, remainder) = IMAPKit.splitResponses(buffer)
            buffer = remainder
            collected += responses
            if isComplete(collected) { return collected }
            guard Date() < deadline else { throw IMAPError(message: "Serverul de email nu răspunde.") }
            buffer.append(try await receive())
        }
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false
            func resume(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(.success(()))
                case .failed(let error): resume(.failure(IMAPError(message: "Nu mă pot conecta la serverul de email (\(error.localizedDescription)).")))
                case .waiting(let error): resume(.failure(IMAPError(message: "Serverul de email nu e accesibil (\(error.localizedDescription)).")))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                resume(.failure(IMAPError(message: "Conectarea la serverul de email a durat prea mult.")))
            }
        }
    }

    private func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: IMAPError(message: "Serverul de email a închis conexiunea."))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
