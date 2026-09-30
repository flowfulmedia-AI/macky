import Foundation

/// WhatsApp through the official Mac app: messages are read from the app's local database
/// (ChatStorage.sqlite) and sent by opening the chat with the text filled in and pressing Enter.
/// Nothing goes through unofficial servers, so the account is never at risk.
public enum WhatsAppKit {
    public struct Chat: Equatable, Sendable {
        public var name: String
        public var jid: String
        public var unreadCount: Int
        public var lastMessageDate: Date?
        public var lastMessageText: String?

        public init(name: String, jid: String, unreadCount: Int, lastMessageDate: Date?, lastMessageText: String?) {
            self.name = name
            self.jid = jid
            self.unreadCount = unreadCount
            self.lastMessageDate = lastMessageDate
            self.lastMessageText = lastMessageText
        }

        public var isGroup: Bool { jid.hasSuffix("@g.us") }
    }

    public struct Message: Equatable, Sendable {
        public var date: Date
        public var isFromMe: Bool
        public var sender: String?
        public var text: String
        public var chatName: String?

        public init(date: Date, isFromMe: Bool, sender: String?, text: String, chatName: String? = nil) {
            self.date = date
            self.isFromMe = isFromMe
            self.sender = sender
            self.text = text
            self.chatName = chatName
        }
    }

    /// WhatsApp (Core Data) stores dates as seconds since 1 January 2001.
    public static func date(fromDatabaseTimestamp timestamp: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: timestamp)
    }

    /// "40722111222@s.whatsapp.net" → "40722111222"; groups and broadcasts have no phone number.
    public static func phoneNumber(fromJID jid: String) -> String? {
        guard jid.hasSuffix("@s.whatsapp.net") else { return nil }
        let digits = String(jid.prefix { $0 != "@" }).filter(\.isNumber)
        return digits.count >= 8 ? digits : nil
    }

    /// Turns what the user said into an international number: "0722 111 222" → "40722111222", "+44 7…" → "447…".
    public static func normalizedPhoneNumber(_ text: String, defaultCountryCode: String = "40") -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var digits = trimmed.filter(\.isNumber)
        guard digits.count >= 8, digits.count <= 15,
              trimmed.allSatisfy({ $0.isNumber || " +-().".contains($0) }) else { return nil }
        if trimmed.hasPrefix("+") { return digits }
        if digits.hasPrefix("00") { return String(digits.dropFirst(2)) }
        if digits.hasPrefix("0") { digits = defaultCountryCode + digits.dropFirst() }
        return digits
    }

    /// Opens the chat in the WhatsApp app with the text already typed.
    public static func sendURL(phoneNumber: String, text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "whatsapp"
        components.host = "send"
        components.queryItems = [URLQueryItem(name: "phone", value: phoneNumber), URLQueryItem(name: "text", value: text)]
        return components.url
    }

    /// What to show for a message without text.
    public static func placeholder(forMessageType messageType: Int) -> String {
        switch messageType {
        case 1: return "[imagine]"
        case 2: return "[video]"
        case 3: return "[mesaj vocal]"
        case 4: return "[contact]"
        case 5: return "[locație]"
        case 7: return "[link]"
        case 8: return "[document]"
        case 11: return "[GIF]"
        case 15: return "[sticker]"
        default: return "[media]"
        }
    }

    /// The chat whose name best matches: exact, then starts with, then contains (diacritics and case ignored),
    /// preferring the most recent among equally good matches.
    public static func bestChat(named name: String, in chats: [Chat]) -> Chat? {
        let wanted = fold(name)
        guard !wanted.isEmpty else { return nil }
        func score(_ chat: Chat) -> Int {
            let chatName = fold(chat.name)
            if chatName == wanted { return 3 }
            if chatName.hasPrefix(wanted) || chatName.split(separator: " ").contains(where: { $0.hasPrefix(wanted) }) { return 2 }
            if chatName.contains(wanted) || wanted.contains(chatName) && chatName.count >= 3 { return 1 }
            return 0
        }
        return chats
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .max { first, second in
                if first.1 != second.1 { return first.1 < second.1 }
                return (first.0.lastMessageDate ?? .distantPast) < (second.0.lastMessageDate ?? .distantPast)
            }?.0
    }

    public static func chatListText(_ chats: [Chat], now: Date = Date()) -> String {
        guard !chats.isEmpty else { return "No chats." }
        return chats.map { chat in
            var line = "\(chat.name)\(chat.isGroup ? " (grup)" : "")"
            if chat.unreadCount > 0 { line += " · \(chat.unreadCount) necitite" }
            if let date = chat.lastMessageDate { line += " · \(shortDate(date, now: now))" }
            if let text = chat.lastMessageText, !text.isEmpty { line += " · „\(String(text.prefix(80)))”" }
            return line
        }.joined(separator: "\n")
    }

    /// Oldest first, one line per message.
    public static func transcript(_ messages: [Message], now: Date = Date()) -> String {
        guard !messages.isEmpty else { return "No messages." }
        return messages.sorted { $0.date < $1.date }.map { message in
            let who = message.isFromMe ? "Eu" : (message.sender ?? message.chatName ?? "Ei")
            let chat = message.chatName.map { "\($0) · " } ?? ""
            return "[\(chat)\(shortDate(message.date, now: now))] \(who): \(message.text)"
        }.joined(separator: "\n")
    }

    static func shortDate(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ro_RO")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
