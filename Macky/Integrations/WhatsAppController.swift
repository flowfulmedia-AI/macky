import AppKit
import Foundation
import MackyCore
import SQLite3

/// WhatsApp through the official Mac app (from the App Store or whatsapp.com).
/// Reading: the app's own database, opened read-only (a copy is used when WhatsApp holds a lock).
/// Sending: opens the chat with the message typed, presses Enter, then checks the database that it was sent.
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
            return (try? Self.rows(database, withSenders, read)) ?? (try Self.rows(database, plain, read))
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

    /// Returns a short result for the model; throws when it cannot be sent or confirmed.
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
                throw WhatsAppError.unreadable("„\(chat.name)” e un grup; deocamdată pot trimite doar mesaje către persoane.")
            }
            phoneNumber = number
            displayName = chat.name
        }
        guard let url = WhatsAppKit.sendURL(phoneNumber: phoneNumber, text: text), NSWorkspace.shared.open(url) else {
            throw WhatsAppError.appNotInstalled
        }
        // Wait for WhatsApp to come to the front with the chat open and the text typed.
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased().contains("whatsapp") == true { break }
        }
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased().contains("whatsapp") == true else {
            throw WhatsAppError.unreadable("aplicația WhatsApp nu s-a deschis.")
        }
        executor.press(KeyCombination(keyCode: 36, modifiers: [], displayName: "Enter"))

        // Confirm it in the database: the newest message from me in that chat should be this text.
        let sentAfter = Date().addingTimeInterval(-20)
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let recent = try? messages(inChatNamed: displayName, limit: 5)?.messages,
               recent.contains(where: { $0.isFromMe && $0.date >= sentAfter && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                return "Sent to \(displayName) and confirmed in WhatsApp."
            }
        }
        return "The message was typed in WhatsApp for \(displayName) and Enter was pressed, but I could not confirm it in the database yet."
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
