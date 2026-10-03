import Foundation

/// One file inside an email.
public struct EmailAttachment: Equatable, Sendable {
    public var fileName: String
    public var mimeType: String
    public var data: Data
    /// Shown inside the message (logos, signatures) rather than attached by the sender.
    public var isInline: Bool

    public init(fileName: String, mimeType: String, data: Data, isInline: Bool) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
        self.isInline = isInline
    }

    /// Worth saving: real attachments, not the little images a newsletter shows inline.
    public var isDocument: Bool {
        if mimeType.hasPrefix("image/") && (isInline || data.count < 20_000) { return false }
        if ["text/calendar", "application/pkcs7-signature", "application/pgp-signature"].contains(mimeType) { return false }
        return true
    }
}

/// A whole email (RFC 822, as Gmail's "raw" format and IMAP's BODY[] give it), parsed for its files and its readable body.
public struct ParsedEmail: Sendable {
    public var headers: [String: String]
    public var attachments: [EmailAttachment]
    /// The HTML part (or the plain text turned into simple HTML), to keep an email without attachments as a PDF.
    public var html: String

    public var subject: String { MIME.decodeWords(EmailFiles.utf8Header(headers["subject"] ?? "")) }
    public var from: String { MIME.decodeWords(EmailFiles.utf8Header(headers["from"] ?? "")) }
    public var date: Date? { EmailFiles.parseDate(headers["date"] ?? "") }
}

public enum EmailFiles {
    public static func parse(rawMessage: Data) -> ParsedEmail {
        // Latin-1 maps every byte to one character, so binary parts survive the round trip back to bytes.
        let text = (String(data: rawMessage, encoding: .isoLatin1) ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        var attachments: [EmailAttachment] = []
        var htmlPart: String?
        var plainPart: String?
        let (headerText, body) = split(text)
        let headers = MIME.headers(headerText + "\n")
        walk(headers: headers, body: body, attachments: &attachments, html: &htmlPart, plain: &plainPart, depth: 0)
        let html = htmlPart ?? "<html><head><meta charset=\"utf-8\"></head><body><pre style=\"font-family: -apple-system, Helvetica; white-space: pre-wrap\">"
            + MarkdownHTML.escape(plainPart ?? "") + "</pre></body></html>"
        return ParsedEmail(headers: headers, attachments: attachments, html: html)
    }

    /// Headers were read byte by byte (Latin-1); modern mail may carry raw UTF-8 in them.
    static func utf8Header(_ text: String) -> String {
        text.data(using: .isoLatin1).flatMap { String(data: $0, encoding: .utf8) } ?? text
    }

    private static func split(_ part: String) -> (headers: String, body: String) {
        // A part without headers starts with the empty line.
        if part.hasPrefix("\n") { return ("", String(part.dropFirst())) }
        guard let separator = part.range(of: "\n\n") else { return (part, "") }
        return (String(part[..<separator.lowerBound]), String(part[separator.upperBound...]))
    }

    private static func walk(headers: [String: String], body: String, attachments: inout [EmailAttachment],
                             html: inout String?, plain: inout String?, depth: Int) {
        let contentType = headers["content-type"] ?? "text/plain"
        let mimeType = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        if mimeType.hasPrefix("multipart/"), depth < 8, let boundary = MIME.parameter("boundary", in: contentType) {
            for part in body.components(separatedBy: "--" + boundary).dropFirst() {
                if part.hasPrefix("--") { break }
                let trimmed = part.hasPrefix("\n") ? String(part.dropFirst()) : part
                let (partHeaderText, partBody) = split(trimmed)
                walk(headers: MIME.headers(partHeaderText + "\n"), body: partBody, attachments: &attachments, html: &html, plain: &plain, depth: depth + 1)
            }
            return
        }
        let disposition = headers["content-disposition"] ?? ""
        let fileName = parameterValue("filename", in: disposition) ?? parameterValue("name", in: contentType)
        let isAttachment = disposition.lowercased().hasPrefix("attachment")
        if fileName != nil || isAttachment || mimeType == "application/pdf" {
            let data = bytes(of: body, transferEncoding: headers["content-transfer-encoding"])
            let name = fileName.map { MIME.decodeWords(utf8Header($0)) } ?? defaultName(for: mimeType, index: attachments.count + 1)
            let isInline = !isAttachment && (disposition.lowercased().hasPrefix("inline") || headers["content-id"] != nil)
            attachments.append(EmailAttachment(fileName: name, mimeType: mimeType, data: data, isInline: isInline))
        } else if mimeType == "text/html", html == nil {
            html = textContent(headers: headers, body: body)
        } else if mimeType == "text/plain", plain == nil {
            plain = textContent(headers: headers, body: body)
        } else if mimeType == "message/rfc822" {
            let (innerHeaders, innerBody) = split(body)
            walk(headers: MIME.headers(innerHeaders + "\n"), body: innerBody, attachments: &attachments, html: &html, plain: &plain, depth: depth + 1)
        }
    }

    private static func bytes(of body: String, transferEncoding: String?) -> Data {
        switch transferEncoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            return Data(base64Encoded: body.components(separatedBy: .whitespacesAndNewlines).joined(), options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return MIME.quotedPrintableBytes(body)
        default:
            return body.data(using: .isoLatin1) ?? Data()
        }
    }

    private static func textContent(headers: [String: String], body: String) -> String {
        let data = bytes(of: body, transferEncoding: headers["content-transfer-encoding"])
        let charset = MIME.parameter("charset", in: headers["content-type"] ?? "") ?? "utf-8"
        return MIME.decode(data, charset: charset)
    }

    /// filename="factura.pdf", filename*=UTF-8''factur%C4%83.pdf, or the split form filename*0*=…; filename*1*=….
    static func parameterValue(_ name: String, in headerValue: String) -> String? {
        var pieces: [(index: Int, value: String, encoded: Bool)] = []
        var plainValue: String?
        for piece in headerValue.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].lowercased()
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if key == name {
                plainValue = value
            } else if key.hasPrefix(name + "*") {
                let rest = key.dropFirst(name.count + 1)
                let encoded = rest.hasSuffix("*") || rest.isEmpty
                let index = Int(rest.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
                pieces.append((index, value, encoded))
            }
        }
        guard !pieces.isEmpty else { return plainValue }
        var charset = "utf-8"
        var bytes = Data()
        for piece in pieces.sorted(by: { $0.index < $1.index }) {
            var value = piece.value
            if piece.index == 0, piece.encoded {
                let parts = value.components(separatedBy: "'")
                if parts.count >= 3 {
                    charset = parts[0].isEmpty ? "utf-8" : parts[0]
                    value = parts[2...].joined(separator: "'")
                }
            }
            if piece.encoded {
                bytes.append(percentDecoded(value))
            } else {
                bytes.append(Data(value.utf8))
            }
        }
        return MIME.decode(bytes, charset: charset)
    }

    private static func percentDecoded(_ text: String) -> Data {
        var result = Data()
        let characters = Array(text.utf8)
        var index = 0
        while index < characters.count {
            if characters[index] == UInt8(ascii: "%"), index + 2 < characters.count,
               let value = UInt8(String(decoding: characters[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                result.append(value)
                index += 3
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    private static func defaultName(for mimeType: String, index: Int) -> String {
        let fileExtension: String
        switch mimeType {
        case "application/pdf": fileExtension = "pdf"
        case "application/xml", "text/xml": fileExtension = "xml"
        case "image/png": fileExtension = "png"
        case "image/jpeg": fileExtension = "jpg"
        case "application/zip": fileExtension = "zip"
        default: fileExtension = "bin"
        }
        return "atasament-\(index).\(fileExtension)"
    }

    // MARK: Files and folders

    /// Safe on macOS: no slashes or colons, no leading dots, not too long.
    public static func safeFileName(_ name: String, fallback: String = "fisier") -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var cleaned = name.components(separatedBy: forbidden).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if cleaned.isEmpty { cleaned = fallback }
        if cleaned.count > 150 {
            let fileExtension = (cleaned as NSString).pathExtension
            let stem = String((cleaned as NSString).deletingPathExtension.prefix(140))
            cleaned = fileExtension.isEmpty ? stem : stem + "." + fileExtension
        }
        return cleaned
    }

    /// "factura.pdf" → "factura (2).pdf" when the name is taken.
    public static func uniqueFileName(_ name: String, existing: (String) -> Bool) -> String {
        guard existing(name) else { return name }
        let stem = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = "\(stem) (\(number))" + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
            if !existing(candidate) { return candidate }
            number += 1
        }
    }

    /// Where the user wants the files: "Facturi octombrie" → ~/Downloads/Facturi octombrie; "~/Documents/X" and
    /// "Documents/X" are taken as given. Always inside the home folder.
    public static func folderPath(for requested: String, homeDirectory: String) -> String {
        var path = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if path.hasPrefix("~/") { path = home + "/" + path.dropFirst(2) }
        if path.hasPrefix(home + "/") {
            // Already absolute in the home folder.
        } else if path.hasPrefix("/") {
            path = home + "/Downloads/" + (path as NSString).lastPathComponent
        } else {
            let first = path.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
            let homeFolders = ["downloads", "documents", "desktop", "documente", "descărcări", "birou"]
            let mapped: [String: String] = ["documente": "Documents", "descărcări": "Downloads", "birou": "Desktop"]
            if homeFolders.contains(first) {
                let rest = path.split(separator: "/").dropFirst().joined(separator: "/")
                let folder = mapped[first] ?? first.prefix(1).uppercased() + first.dropFirst()
                path = home + "/" + folder + (rest.isEmpty ? "" : "/" + rest)
            } else {
                path = home + "/Downloads/" + path
            }
        }
        // No climbing out with "..".
        let components = path.split(separator: "/").filter { $0 != ".." && $0 != "." }
        let normalized = "/" + components.joined(separator: "/")
        return normalized.hasPrefix(home) ? normalized : home + "/Downloads"
    }

    /// The name for an email kept as a PDF: "2026-10-01 Apple - Your receipt from Apple.pdf".
    public static func documentName(for email: ParsedEmail) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = email.date.map(formatter.string(from:)) ?? ""
        var sender = email.from
        if let angle = sender.firstIndex(of: "<") { sender = String(sender[..<angle]) }
        sender = sender.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        if sender.isEmpty { sender = email.from }
        let subject = email.subject.isEmpty ? "email" : email.subject
        return safeFileName([day, sender + " - " + subject].filter { !$0.isEmpty }.joined(separator: " ") + ".pdf")
    }

    /// "Thu, 1 Oct 2026 09:00:00 +0300 (EEST)"
    public static func parseDate(_ text: String) -> Date? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        if let parenthesis = cleaned.firstIndex(of: "(") { cleaned = cleaned[..<parenthesis].trimmingCharacters(in: .whitespaces) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}
