import Foundation

/// Email accounts that are not Gmail (Yahoo, iCloud, Outlook…), read over IMAP with an app password.
/// Read-only: Macky opens the inbox with EXAMINE, so nothing is marked as read, moved or deleted.
public struct IMAPAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: String { emailAddress.lowercased() }
    public var emailAddress: String
    public var host: String
    public var port: Int

    public init(emailAddress: String, host: String, port: Int = 993) {
        self.emailAddress = emailAddress
        self.host = host
        self.port = port
    }

    public enum Provider: String, CaseIterable, Identifiable, Sendable {
        case yahoo, icloud, outlook, other
        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .yahoo: return "Yahoo"
            case .icloud: return "iCloud"
            case .outlook: return "Outlook / Hotmail"
            case .other: return "Alt furnizor"
            }
        }

        public var host: String? {
            switch self {
            case .yahoo: return "imap.mail.yahoo.com"
            case .icloud: return "imap.mail.me.com"
            case .outlook: return "outlook.office365.com"
            case .other: return nil
            }
        }

        /// Where the user creates the app password the account needs.
        public var appPasswordHelp: String {
            switch self {
            case .yahoo: return "Yahoo: login.yahoo.com → Account Info → Account Security → Generate app password (alege „Other app”, nume „Macky”)."
            case .icloud: return "iCloud: account.apple.com → Sign-In and Security → App-Specific Passwords → +."
            case .outlook: return "Outlook: account.microsoft.com → Security → Advanced security options → App passwords (cere verificarea în doi pași)."
            case .other: return "Folosește adresa serverului IMAP și o parolă de aplicație de la furnizorul tău."
            }
        }

        public static func guess(for emailAddress: String) -> Provider {
            let domain = emailAddress.split(separator: "@").last.map { $0.lowercased() } ?? ""
            if domain.hasPrefix("yahoo.") || domain.hasPrefix("ymail.") || domain == "rocketmail.com" { return .yahoo }
            if ["icloud.com", "me.com", "mac.com"].contains(domain) { return .icloud }
            if domain.hasPrefix("outlook.") || domain.hasPrefix("hotmail.") || domain.hasPrefix("live.") || domain == "msn.com" { return .outlook }
            return .other
        }
    }
}

public struct IMAPMessage: Equatable, Sendable {
    public var uid: Int
    public var from: String
    public var subject: String
    public var date: String
    public var isUnread: Bool
    public var bodyText: String

    public init(uid: Int, from: String, subject: String, date: String, isUnread: Bool, bodyText: String = "") {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.isUnread = isUnread
        self.bodyText = bodyText
    }
}

public enum IMAPKit {
    // MARK: Commands

    /// An IMAP quoted string.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Translates the Gmail-style queries Macky's model writes ("from:andrei is:unread newer_than:2d factura")
    /// into IMAP SEARCH criteria. Unknown operators become plain text searches.
    public static func searchCriteria(fromGmailQuery query: String, now: Date = Date()) -> String {
        var criteria: [String] = []
        var freeWords: [String] = []
        for token in tokenize(query) {
            let lowered = token.lowercased()
            func value(after prefix: String) -> String { String(token.dropFirst(prefix.count)) }
            if lowered.hasPrefix("from:") {
                criteria.append("FROM " + quoted(value(after: "from:")))
            } else if lowered.hasPrefix("to:") {
                criteria.append("TO " + quoted(value(after: "to:")))
            } else if lowered.hasPrefix("subject:") {
                criteria.append("SUBJECT " + quoted(value(after: "subject:")))
            } else if lowered == "is:unread" {
                criteria.append("UNSEEN")
            } else if lowered == "is:read" {
                criteria.append("SEEN")
            } else if lowered == "is:starred" {
                criteria.append("FLAGGED")
            } else if lowered.hasPrefix("newer_than:"), let since = sinceDate(value(after: "newer_than:"), now: now) {
                criteria.append("SINCE " + since)
            } else if lowered.hasPrefix("after:"), let date = slashDate(value(after: "after:")) {
                criteria.append("SINCE " + date)
            } else if lowered.hasPrefix("before:"), let date = slashDate(value(after: "before:")) {
                criteria.append("BEFORE " + date)
            } else if lowered.hasPrefix("in:") || lowered.hasPrefix("label:") || lowered.hasPrefix("category:") || lowered.hasPrefix("has:") {
                continue
            } else {
                freeWords.append(token)
            }
        }
        if !freeWords.isEmpty {
            criteria.append("TEXT " + quoted(freeWords.joined(separator: " ")))
        }
        return criteria.isEmpty ? "ALL" : criteria.joined(separator: " ")
    }

    /// Splits on spaces but keeps "quoted phrases" and from:"Ana Pop" together.
    static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in query {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == " " && !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func sinceDate(_ value: String, now: Date) -> String? {
        guard let unit = value.last, let amount = Int(value.dropLast()) else { return nil }
        let days: Int
        switch unit {
        case "d": days = amount
        case "w": days = amount * 7
        case "m": days = amount * 30
        case "y": days = amount * 365
        default: return nil
        }
        return imapDate(now.addingTimeInterval(-Double(days) * 86_400))
    }

    private static func slashDate(_ value: String) -> String? {
        let parts = value.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components).map(imapDate)
    }

    /// IMAP's date format: 02-Oct-2026.
    public static func imapDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "dd-MMM-yyyy"
        return formatter.string(from: date)
    }

    // MARK: Responses

    /// One server response: its text (literals left out) and its literals ({123}\r\n + 123 bytes) in order.
    public struct Response: Equatable, Sendable {
        public var text: String
        public var literals: [Data]
    }

    /// Splits raw server output into complete responses; the bytes of an unfinished one are returned to wait for more data.
    public static func splitResponses(_ data: Data) -> (responses: [Response], remainder: Data) {
        let bytes = [UInt8](data)
        var responses: [Response] = []
        var position = 0
        var responseStart = 0
        var text: [UInt8] = []
        var literals: [Data] = []
        while position < bytes.count {
            guard let lineEnd = findCRLF(bytes, from: position) else { break }
            let line = Array(bytes[position..<lineEnd])
            text += line
            var next = lineEnd + 2
            if let length = literalLength(at: Data(line)) {
                guard next + length <= bytes.count else { break }
                literals.append(Data(bytes[next..<(next + length)]))
                next += length
                position = next
                // The response goes on after the literal.
                continue
            }
            responses.append(Response(text: String(decoding: text, as: UTF8.self), literals: literals))
            text = []
            literals = []
            position = next
            responseStart = position
        }
        return (responses, Data(bytes[responseStart...]))
    }

    private static func findCRLF(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 13 && bytes[index + 1] == 10 { return index }
            index += 1
        }
        return nil
    }

    /// "… {1234}" at the end of a line announces a literal of 1234 bytes.
    static func literalLength(at line: Data) -> Int? {
        let text = String(decoding: line, as: UTF8.self)
        guard text.hasSuffix("}"), let open = text.lastIndex(of: "{") else { return nil }
        return Int(text[text.index(after: open)..<text.index(before: text.endIndex)].replacingOccurrences(of: "+", with: ""))
    }

    /// The UIDs in "* SEARCH 4 8 15".
    public static func searchResults(in responses: [Response]) -> [Int] {
        responses.filter { $0.text.hasPrefix("* SEARCH") }.flatMap { response in
            response.text.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    /// One FETCH response: its UID, flags and the literal sections (headers, text) in order.
    public struct FetchedItem: Equatable, Sendable {
        public var uid: Int
        public var flags: [String]
        public var sections: [Data]
    }

    public static func fetchedItems(in responses: [Response]) -> [FetchedItem] {
        responses.compactMap { response in
            let text = response.text
            guard text.hasPrefix("* "), text.contains(" FETCH "), let uid = number(after: "UID ", in: text) else { return nil }
            var flags: [String] = []
            if let flagsRange = text.range(of: "FLAGS ("), let close = text[flagsRange.upperBound...].firstIndex(of: ")") {
                flags = text[flagsRange.upperBound..<close].split(separator: " ").map(String.init)
            }
            return FetchedItem(uid: uid, flags: flags, sections: response.literals)
        }
    }

    private static func number(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    /// The tagged completion ("a3 OK …" / "a3 NO …"), if it arrived.
    public static func completion(of tag: String, in responses: [Response]) -> (ok: Bool, text: String)? {
        guard let line = responses.first(where: { $0.text.hasPrefix(tag + " ") })?.text else { return nil }
        let rest = line.dropFirst(tag.count + 1)
        return (rest.hasPrefix("OK"), String(rest))
    }

    // MARK: Messages

    /// Builds a message from its fetched header and (optional) text sections.
    public static func message(from item: FetchedItem) -> IMAPMessage {
        let headers = MIME.headers(MIME.text(item.sections.first ?? Data()))
        let body = item.sections.count > 1 ? MIME.readableText(headers: headers, body: MIME.text(item.sections[1])) : ""
        return IMAPMessage(
            uid: item.uid,
            from: MIME.decodeWords(headers["from"] ?? ""),
            subject: MIME.decodeWords(headers["subject"] ?? "(fără subiect)"),
            date: headers["date"] ?? "",
            isUnread: !item.flags.contains("\\Seen"),
            bodyText: body
        )
    }
}

/// Just enough MIME to read an email: headers, encoded words, multipart, quoted-printable and base64.
public enum MIME {
    /// Raw message bytes as text: UTF-8 when valid, otherwise Windows-1252 (8-bit Western emails).
    public static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Header names in lowercase; folded lines joined.
    public static func headers(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var lastName: String?
        // "\r\n" is a single Character in Swift: normalize before splitting.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { break }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let lastName {
                result[lastName, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].lowercased()
                result[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                lastName = name
            }
        }
        return result
    }

    /// =?UTF-8?B?…?= and =?iso-8859-2?Q?…?= in headers.
    public static func decodeWords(_ text: String) -> String {
        guard text.contains("=?"),
              let expression = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=(\\s+(?==\\?))?") else { return text }
        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let charset = nsText.substring(with: match.range(at: 1))
            let encoding = nsText.substring(with: match.range(at: 2)).uppercased()
            let payload = nsText.substring(with: match.range(at: 3))
            let bytes = encoding == "B"
                ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
                : quotedPrintableBytes(payload.replacingOccurrences(of: "_", with: " "))
            result += bytes.map { decode($0, charset: charset) } ?? payload
            lastEnd = match.range.location + match.range.length
        }
        return result + nsText.substring(from: lastEnd)
    }

    /// The plain text of a message body; for multipart, the text/plain part (else HTML turned into text).
    public static func readableText(headers: [String: String], body: String, maximumCharacters: Int = 8000) -> String {
        let body = body.replacingOccurrences(of: "\r\n", with: "\n")
        let contentType = headers["content-type"]?.lowercased() ?? "text/plain"
        if contentType.hasPrefix("multipart/"), let boundary = parameter("boundary", in: headers["content-type"] ?? "") {
            let parts = body.components(separatedBy: "--" + boundary).dropFirst()
            var htmlFallback: String?
            for part in parts {
                if part.hasPrefix("--") { break }
                guard let separator = part.range(of: "\n\n") else { continue }
                let partHeaders = MIME.headers(String(part[..<separator.lowerBound]).trimmingCharacters(in: .newlines) + "\n")
                let partBody = String(part[separator.upperBound...])
                let partType = partHeaders["content-type"]?.lowercased() ?? "text/plain"
                if partType.hasPrefix("multipart/") {
                    let nested = readableText(headers: partHeaders, body: partBody, maximumCharacters: maximumCharacters)
                    if !nested.isEmpty { return nested }
                } else if partType.hasPrefix("text/plain") {
                    return String(decodedBody(headers: partHeaders, body: partBody).prefix(maximumCharacters))
                } else if partType.hasPrefix("text/html"), htmlFallback == nil {
                    htmlFallback = decodedBody(headers: partHeaders, body: partBody)
                }
            }
            return htmlFallback.map { HTMLTextExtractor.readableText(fromHTML: $0, maximumCharacters: maximumCharacters) } ?? ""
        }
        let decoded = decodedBody(headers: headers, body: body)
        return contentType.hasPrefix("text/html")
            ? HTMLTextExtractor.readableText(fromHTML: decoded, maximumCharacters: maximumCharacters)
            : String(decoded.prefix(maximumCharacters))
    }

    static func decodedBody(headers: [String: String], body: String) -> String {
        let transferEncoding = headers["content-transfer-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let charset = parameter("charset", in: headers["content-type"] ?? "") ?? "utf-8"
        let bytes: Data
        switch transferEncoding {
        case "base64":
            bytes = Data(base64Encoded: body.components(separatedBy: .whitespacesAndNewlines).joined(), options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            bytes = quotedPrintableBytes(body)
        default:
            bytes = Data(body.utf8)
        }
        return decode(bytes, charset: charset).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `charset="utf-8"` → utf-8.
    static func parameter(_ name: String, in headerValue: String) -> String? {
        for piece in headerValue.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(name + "=") else { continue }
            return trimmed.dropFirst(name.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return nil
    }

    static func quotedPrintableBytes(_ text: String) -> Data {
        var bytes: [UInt8] = []
        let characters = Array(text.utf8)
        var index = 0
        while index < characters.count {
            let byte = characters[index]
            if byte == UInt8(ascii: "=") {
                // Soft line break.
                if index + 1 < characters.count, characters[index + 1] == 13 || characters[index + 1] == 10 {
                    index += characters[index + 1] == 13 && index + 2 < characters.count && characters[index + 2] == 10 ? 3 : 2
                    continue
                }
                if index + 2 < characters.count, let value = UInt8(String(bytes: characters[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                    bytes.append(value)
                    index += 3
                    continue
                }
            }
            bytes.append(byte)
            index += 1
        }
        return Data(bytes)
    }

    static func decode(_ data: Data, charset: String) -> String {
        switch charset.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii":
            return String(decoding: data, as: UTF8.self)
        case "iso-8859-1", "latin1", "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        case "iso-8859-2", "windows-1250", "cp1250":
            return String(data: data, encoding: .windowsCP1250) ?? String(data: data, encoding: .isoLatin2) ?? String(decoding: data, as: UTF8.self)
        default:
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        }
    }
}
