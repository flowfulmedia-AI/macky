import AppKit
import ApplicationServices
import Foundation
import MackyCore
import SQLite3

/// WhatsApp through the official Mac app (from the App Store or whatsapp.com).
/// Reading: the app's own database, opened read-only (a copy is used when WhatsApp holds a lock).
/// Sending: opens the chat with the message typed, presses Enter, then checks the database that it was sent.
/// Groups have no such link: they are opened through WhatsApp's search, checked step by step, and confirmed the same way.
/// macOS asks once for access to the data of other apps (or grant Full Disk Access to Macky).
@MainActor
final class WhatsAppController: ObservableObject {
    @Published private(set) var statusText: String?

    private let settings: AppSettings
    private let executor: ScreenActionExecutor

    static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite")

    enum WhatsAppError: LocalizedError {
        case appNotInstalled
        case noAccess
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .appNotInstalled:
                return "Nu găsesc aplicația WhatsApp pentru Mac (din App Store). Instaleaz-o și conectează-te în ea."
            case .noAccess:
                return "Macky nu are voie să citească WhatsApp. Permite accesul la datele altor aplicații sau dă-i lui Macky Full Disk Access (System Settings → Privacy & Security)."
            case .unreadable(let reason):
                return "Nu pot citi WhatsApp: \(reason)"
            }
        }
    }

    init(settings: AppSettings, executor: ScreenActionExecutor) {
        self.settings = settings
        self.executor = executor
    }

    var isAvailable: Bool {
        settings.whatsAppEnabled && FileManager.default.fileExists(atPath: Self.databaseURL.path)
    }

    // MARK: Reading

    func chats(unreadOnly: Bool, limit: Int) throws -> [WhatsAppKit.Chat] {
        try withDatabase { database in
            let sql = """
            SELECT ZPARTNERNAME, ZCONTACTJID, ZUNREADCOUNT, ZLASTMESSAGEDATE, ZLASTMESSAGETEXT
            FROM ZWACHATSESSION
            WHERE ZCONTACTJID IS NOT NULL AND ZCONTACTJID NOT LIKE '%@status' AND ZCONTACTJID NOT LIKE '%broadcast%'
            \(unreadOnly ? "AND ZUNREADCOUNT > 0" : "")
            ORDER BY ZLASTMESSAGEDATE DESC LIMIT \(limit)
            """
            return try Self.rows(database, sql) { statement in
                WhatsAppKit.Chat(
                    name: Self.text(statement, 0) ?? Self.text(statement, 1) ?? "?",
                    jid: Self.text(statement, 1) ?? "",
                    unreadCount: Int(sqlite3_column_int(statement, 2)),
                    lastMessageDate: Self.date(statement, 3),
                    lastMessageText: Self.text(statement, 4)
                )
            }
        }
    }

    func messages(inChatNamed name: String, limit: Int) throws -> (chat: WhatsAppKit.Chat, messages: [WhatsAppKit.Message])? {
        guard let chat = WhatsAppKit.bestChat(named: name, in: try chats(unreadOnly: false, limit: 500)) else { return nil }
        let messages = try withDatabase { database -> [WhatsAppKit.Message] in
            let escapedJID = chat.jid.replacingOccurrences(of: "'", with: "''")
            let withSenders = """
            SELECT m.ZMESSAGEDATE, m.ZISFROMME, m.ZTEXT, m.ZMESSAGETYPE, g.ZCONTACTNAME
            FROM ZWAMESSAGE m LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
            WHERE m.ZCHATSESSION = (SELECT Z_PK FROM ZWACHATSESSION WHERE ZCONTACTJID = '\(escapedJID)')
            ORDER BY m.ZMESSAGEDATE DESC LIMIT \(limit)
            """
            let plain = """
            SELECT m.ZMESSAGEDATE, m.ZISFROMME, m.ZTEXT, m.ZMESSAGETYPE, NULL
            FROM ZWAMESSAGE m
            WHERE m.ZCHATSESSION = (SELECT Z_PK FROM ZWACHATSESSION WHERE ZCONTACTJID = '\(escapedJID)')
            ORDER BY m.ZMESSAGEDATE DESC LIMIT \(limit)
            """
            let read: (OpaquePointer?) -> WhatsAppKit.Message = { statement in
                let text = Self.text(statement, 2) ?? WhatsAppKit.placeholder(forMessageType: Int(sqlite3_column_int(statement, 3)))
                return WhatsAppKit.Message(date: Self.date(statement, 0) ?? .distantPast, isFromMe: sqlite3_column_int(statement, 1) != 0,
                                           sender: Self.text(statement, 4), text: text)
            }
            // Older databases have no group member table: fall back to the plain query.
            if let rows = try? Self.rows(database, withSenders, read) { return rows }
            return try Self.rows(database, plain, read)
        }
        return (chat, messages)
    }

    func search(_ query: String, limit: Int = 30) throws -> [WhatsAppKit.Message] {
        try withDatabase { database in
            let pattern = "%" + query.replacingOccurrences(of: "'", with: "''") + "%"
            let sql = """
            SELECT m.ZMESSAGEDATE, m.ZISFROMME, m.ZTEXT, s.ZPARTNERNAME
            FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            WHERE m.ZTEXT LIKE '\(pattern)'
            ORDER BY m.ZMESSAGEDATE DESC LIMIT \(limit)
            """
            return try Self.rows(database, sql) { statement in
                WhatsAppKit.Message(date: Self.date(statement, 0) ?? .distantPast, isFromMe: sqlite3_column_int(statement, 1) != 0,
                                    sender: nil, text: Self.text(statement, 2) ?? "", chatName: Self.text(statement, 3))
            }
        }
    }

    // MARK: Sending

    /// Sends and confirms in WhatsApp's database; throws with a clear reason when it cannot be sent or confirmed.
    func send(to recipient: String, text: String) async throws -> String {
        let phoneNumber: String
        let displayName: String
        if let number = WhatsAppKit.normalizedPhoneNumber(recipient, defaultCountryCode: settings.whatsAppCountryCode) {
            phoneNumber = number
            displayName = recipient
        } else {
            guard let chat = WhatsAppKit.bestChat(named: recipient, in: try chats(unreadOnly: false, limit: 500)) else {
                throw WhatsAppError.unreadable("nu găsesc o conversație cu „\(recipient)”. Spune numele exact din WhatsApp sau numărul de telefon.")
            }
            guard let number = WhatsAppKit.phoneNumber(fromJID: chat.jid) else {
                return try await sendToGroup(chat, text: text)
            }
            phoneNumber = number
            displayName = chat.name
        }
        let sentAfter = Date().addingTimeInterval(-5)
        guard let url = WhatsAppKit.sendURL(phoneNumber: phoneNumber, text: text), NSWorkspace.shared.open(url) else {
            throw WhatsAppError.appNotInstalled
        }
        try await waitForWhatsAppInFront()
        executor.press(KeyCombination(keyCode: 36, modifiers: [], displayName: "Enter"))
        return try await confirmSent(text, toChatNamed: displayName, since: sentAfter)
    }

    /// WhatsApp has no link that opens a group, so Macky uses WhatsApp's own search, checking at each step
    /// (through Accessibility) that the right field has the focus. If anything looks off it stops before typing.
    private func sendToGroup(_ chat: WhatsAppKit.Chat, text: String) async throws -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp")
                ?? ScreenActionExecutor.findApplication(named: "WhatsApp") else {
            throw WhatsAppError.appNotInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        try await waitForWhatsAppInFront()
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw WhatsAppError.unreadable("aplicația WhatsApp nu s-a deschis.")
        }
        let sentAfter = Date().addingTimeInterval(-5)

        // 1. The chat search field.
        executor.press(KeyCombination(keyCode: 53, modifiers: [], displayName: "Escape"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        executor.press(KeyCombination(keyCode: 3, modifiers: .command, displayName: "⌘F"))
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard let searchField = Self.focusedTextElement(ofProcess: processIdentifier) else {
            throw WhatsAppError.unreadable("nu am putut deschide căutarea din WhatsApp, așa că nu am scris nimic. Deschide grupul „\(chat.name)” și cere-mi din nou.")
        }
        executor.press(KeyCombination(keyCode: 0, modifiers: .command, displayName: "⌘A"))
        await executor.type(chat.name, pressEnterAfterwards: false)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // 2. Open the first result: the message box must now have the focus, not the search field.
        executor.press(KeyCombination(keyCode: 125, modifiers: [], displayName: "↓"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        executor.press(KeyCombination(keyCode: 36, modifiers: [], displayName: "Enter"))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let messageBox = Self.focusedTextElement(ofProcess: processIdentifier), !CFEqual(messageBox, searchField) else {
            executor.press(KeyCombination(keyCode: 53, modifiers: [], displayName: "Escape"))
            throw WhatsAppError.unreadable("nu am reușit să deschid grupul „\(chat.name)” din căutare, așa că nu am trimis nimic.")
        }

        // 3. Type, send, and confirm in the database that it landed in this group.
        await executor.type(text, pressEnterAfterwards: true)
        return try await confirmSent(text, toChatNamed: chat.name, since: sentAfter)
    }

    /// Looks in WhatsApp's database for the message; if it went to another chat, says which.
    private func confirmSent(_ text: String, toChatNamed chatName: String, since sentAfter: Date) async throws -> String {
        let wanted = Self.comparable(text)
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let recent = try? messages(inChatNamed: chatName, limit: 8)?.messages,
               recent.contains(where: { $0.isFromMe && $0.date >= sentAfter && Self.comparable($0.text) == wanted }) {
                return "Sent to \(chatName) and confirmed in WhatsApp."
            }
        }
        if let elsewhere = try? recentOutgoingChat(matching: wanted, since: sentAfter), elsewhere != chatName {
            throw WhatsAppError.unreadable("mesajul a ajuns în „\(elsewhere)”, nu în „\(chatName)”. Verifică WhatsApp.")
        }
        throw WhatsAppError.unreadable("nu văd mesajul trimis în „\(chatName)”. Verifică WhatsApp: poate a rămas scris, netrimis.")
    }

    private func recentOutgoingChat(matching wanted: String, since date: Date) throws -> String? {
        try withDatabase { database in
            let sql = """
            SELECT s.ZPARTNERNAME, m.ZTEXT FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            WHERE m.ZISFROMME = 1 AND m.ZMESSAGEDATE >= \(date.timeIntervalSinceReferenceDate)
            ORDER BY m.ZMESSAGEDATE DESC LIMIT 20
            """
            return try Self.rows(database, sql) { statement in (Self.text(statement, 0), Self.text(statement, 1)) }
                .first { Self.comparable($0.1 ?? "") == wanted }?.0
        }
    }

    private static func comparable(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The focused element of the app, when it is a text field or text area.
    private static func focusedTextElement(ofProcess processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleName = role as? String ?? ""
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]
        return textRoles.contains(roleName) ? element : nil
    }

    private func waitForWhatsAppInFront() async throws {
        func isInFront() -> Bool {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased().contains("whatsapp") == true
        }
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if isInFront() { break }
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard isInFront() else { throw WhatsAppError.unreadable("aplicația WhatsApp nu s-a deschis.") }
    }

    // MARK: Status

    func checkAccess() {
        guard settings.whatsAppEnabled else {
            statusText = "Oprit."
            return
        }
        do {
            let count = try chats(unreadOnly: false, limit: 500).count
            let unread = (try? chats(unreadOnly: true, limit: 500).count) ?? 0
            statusText = "Conectat · \(count) conversații · \(unread) cu mesaje necitite"
        } catch {
            statusText = error.localizedDescription
        }
    }

    // MARK: SQLite

    /// Opens the database read-only. If WhatsApp holds it locked, reads a fresh copy instead.
    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: Self.databaseURL.path) else { throw WhatsAppError.appNotInstalled }
        do {
            return try Self.open(Self.databaseURL, body)
        } catch WhatsAppError.noAccess {
            throw WhatsAppError.noAccess
        } catch {
            let copyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("macky-whatsapp", isDirectory: true)
            try? FileManager.default.removeItem(at: copyFolder)
            try FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copyFolder) }
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: Self.databaseURL.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                do {
                    try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copyFolder.appendingPathComponent("ChatStorage.sqlite").path + suffix))
                } catch {
                    throw WhatsAppError.noAccess
                }
            }
            return try Self.open(copyFolder.appendingPathComponent("ChatStorage.sqlite"), body)
        }
    }

    private static func open<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard result == SQLITE_OK, let database else {
            if result == SQLITE_CANTOPEN || result == SQLITE_PERM || result == SQLITE_AUTH { throw WhatsAppError.noAccess }
            throw WhatsAppError.unreadable("SQLite \(result)")
        }
        sqlite3_busy_timeout(database, 1500)
        return try body(database)
    }

    private static func rows<T>(_ database: OpaquePointer, _ sql: String, _ read: (OpaquePointer?) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(database))
            sqlite3_finalize(statement)
            if message.contains("authoriz") || message.contains("permission") { throw WhatsAppError.noAccess }
            throw WhatsAppError.unreadable(message)
        }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                results.append(read(statement))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw WhatsAppError.unreadable(String(cString: sqlite3_errmsg(database)))
            }
        }
        return results
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func date(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return WhatsAppKit.date(fromDatabaseTimestamp: sqlite3_column_double(statement, column))
    }
}
