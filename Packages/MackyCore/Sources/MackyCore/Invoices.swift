import Foundation

/// The monthly "collect every invoice" job, done in one go: one search per service across every email account,
/// then every invoice saved into one folder with a summary file.
public enum InvoiceKit {
    /// Words a bill has in its subject (or its PDF's name), in English and Romanian.
    static let invoiceSubjectWords = ["invoice", "receipt", "factura", "factură", "facturi", "chitanta", "chitanță"]

    /// Who sends a service's bills and how to recognise them.
    public struct ServiceProfile: Equatable, Sendable {
        /// "Apple", "Google One": used in file names.
        public var displayName: String
        /// Words for Gmail's from: (sender name or address).
        public var searchWords: [String]
        /// One of these must be in the sender (name or address) of a real bill.
        public var senderMarks: [String]
        /// Text that must appear in the email too (Google sends far more than Google One bills).
        public var mentions: [String]
    }

    /// Senders of the common services; other services are recognised by their name.
    static let knownServices: [(keys: [String], searchWords: [String], senderMarks: [String], mentions: [String])] = [
        (["apple", "icloud", "app store"], ["apple"], ["apple.com"], []),
        (["google one"], ["google"], ["google.com"], ["google one"]),
        (["openai", "chatgpt"], ["openai"], ["openai"], []),
        (["anthropic", "claude"], ["anthropic"], ["anthropic"], []),
        (["zoom"], ["zoom"], ["zoom.us", "zoom.com"], []),
        (["capcut"], ["capcut"], ["capcut"], []),
        (["microsoft", "office 365", "microsoft 365"], ["microsoft"], ["microsoft"], [])
    ]

    public static func profile(for service: String) -> ServiceProfile {
        let names = aliases(for: service)
        let displayName = names.first ?? service
        let folded: [String] = names.map { (name: String) -> String in name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        if let known = knownServices.first(where: { entry in entry.keys.contains { key in folded.contains(key) } }) {
            return ServiceProfile(displayName: displayName, searchWords: known.searchWords, senderMarks: known.senderMarks, mentions: known.mentions)
        }
        // "Captions.ai" → "captions", "Lovable" → "lovable".
        let base = (folded.first ?? service.lowercased())
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: #"\.(ai|com|io|dev|app|co|net|org|ro)$"#, with: "", options: .regularExpression)
        return ServiceProfile(displayName: displayName, searchWords: [base], senderMarks: [base], mentions: [])
    }

    /// Whether a found email really is this service's bill: right sender, and a bill by its subject or its PDF's name.
    public static func isInvoice(from sender: String, subject: String, attachmentNames: [String], text: String, profile: ServiceProfile) -> Bool {
        func folded(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let senderText = folded(sender)
        guard profile.senderMarks.contains(where: { senderText.contains($0) }) else { return false }
        let subjectText = folded(subject)
        let words = invoiceSubjectWords.map(folded)
        let looksLikeBill = words.contains { subjectText.contains($0) }
            || attachmentNames.contains { name in words.contains { folded(name).contains($0) } }
        guard looksLikeBill else { return false }
        let everything = subjectText + " " + folded(text)
        return profile.mentions.allSatisfy { everything.contains(folded($0)) }
    }

    /// "Factura {serviciu} ({LUNA} {AN})" → "Factura Lovable (SEP 2026)". Also {luna} (sep) and {Luna} (Septembrie).
    public static func fileName(template: String, service: String, date: Date, calendar: Calendar = .current) -> String {
        let shortNames = ["IAN", "FEB", "MAR", "APR", "MAI", "IUN", "IUL", "AUG", "SEP", "OCT", "NOI", "DEC"]
        let longNames = ["Ianuarie", "Februarie", "Martie", "Aprilie", "Mai", "Iunie", "Iulie", "August", "Septembrie", "Octombrie", "Noiembrie", "Decembrie"]
        let month = calendar.component(.month, from: date) - 1
        let year = String(calendar.component(.year, from: date))
        var name = template.isEmpty ? defaultFileNameTemplate : template
        for (placeholder, value) in [("{serviciu}", service), ("{service}", service), ("{LUNA}", shortNames[month]), ("{luna}", shortNames[month].lowercased()),
                                     ("{Luna}", longNames[month]), ("{AN}", year), ("{an}", year)] {
            name = name.replacingOccurrences(of: placeholder, with: value)
        }
        return EmailFiles.safeFileName(name)
    }

    public static let defaultFileNameTemplate = "Factura {serviciu} ({LUNA} {AN})"

    /// "Apple (iCloud / App Store)" → ["Apple", "iCloud", "App Store"].
    public static func aliases(for service: String) -> [String] {
        let separators = CharacterSet(charactersIn: "()/,;|")
        var seen = Set<String>()
        return service.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// "2026-09", "09/2026", "septembrie 2026", "sept 2026" → the first day of that month and of the next one.
    public static func monthRange(_ text: String, calendar: Calendar = Calendar(identifier: .gregorian)) -> (start: Date, end: Date)? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let numbers = folded.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        var year = numbers.first { $0 >= 2000 && $0 < 2100 }
        var month = numbers.first { (1...12).contains($0) }
        let monthNames = [["ian", "jan"], ["feb"], ["mar"], ["apr"], ["mai", "may"], ["iun", "jun"], ["iul", "jul"], ["aug"],
                          ["sep"], ["oct"], ["noi", "nov"], ["dec"]]
        let words = folded.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
        if let index = monthNames.firstIndex(where: { prefixes in words.contains { word in prefixes.contains { word.hasPrefix($0) } } }) {
            month = index + 1
        }
        if year == nil, month != nil { year = calendar.component(.year, from: Date()) }
        guard let year, let month,
              let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// One Gmail-syntax search for one service's bills in a period (IMAP accounts get it translated):
    /// from the service, with a bill word in the subject.
    public static func query(service: String, start: Date, end: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let profile = profile(for: service)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy/MM/dd"
        var parts = ["from:(" + profile.searchWords.joined(separator: " OR ") + ")"]
        parts += profile.mentions.map { "\"\($0)\"" }
        parts.append("subject:(" + invoiceSubjectWords.joined(separator: " OR ") + ")")
        parts.append("after:" + formatter.string(from: start))
        parts.append("before:" + formatter.string(from: end))
        return parts.joined(separator: " ")
    }

    /// The ids in search result lines ("id=gmail:ana@gmail.com#18c… | …").
    public static func identifiers(inSearchLines lines: [String]) -> [String] {
        lines.compactMap { line in
            guard let range = line.range(of: "id=") else { return nil }
            let identifier = line[range.upperBound...].prefix { !$0.isWhitespace && $0 != "|" }
            return identifier.isEmpty ? nil : String(identifier)
        }
    }

    /// The amount paid, as written in the email: the line with "total" first, otherwise the first amount.
    public static func amount(in text: String) -> String? {
        let pattern = #"(?:(?:€|\$|£|US\$|USD|EUR|RON|lei)\s?\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d{2})?|\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d{2})\s?(?:€|\$|£|USD|EUR|RON|lei))"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        func firstAmount(in line: String) -> String? {
            let range = NSRange(line.startIndex..., in: line)
            return expression.firstMatch(in: line, range: range).flatMap { Range($0.range, in: line) }.map { String(line[$0]).trimmingCharacters(in: .whitespaces) }
        }
        // "Total" as a word: "Subtotal" comes before tax.
        let isTotalLine = { (line: String) in
            line.range(of: #"\btotal\b|amount paid|total de plat"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        for (index, line) in lines.enumerated() where isTotalLine(line) {
            if let amount = firstAmount(in: line) { return amount }
            // "Total" on one line, the amount on the next.
            if index + 1 < lines.count, let amount = firstAmount(in: lines[index + 1]) { return amount }
        }
        return lines.lazy.compactMap(firstAmount).first
    }

    public struct SummaryEntry: Equatable, Sendable {
        public var service: String
        public var date: Date?
        public var subject: String
        public var sender: String
        public var amount: String?
        public var files: [String]

        public init(service: String, date: Date?, subject: String, sender: String, amount: String?, files: [String]) {
            self.service = service
            self.date = date
            self.subject = subject
            self.sender = sender
            self.amount = amount
            self.files = files
        }
    }

    /// The text file kept next to the invoices: what each file is, per service, and what was not found.
    public static func summary(title: String, entries: [SummaryEntry], servicesWithoutInvoices: [String]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yyyy"
        var text = title + "\n" + String(repeating: "=", count: min(60, title.count)) + "\n\n"
        let services = entries.map(\.service).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for service in services {
            text += service + "\n"
            for entry in entries where entry.service == service {
                text += "  • " + (entry.date.map(formatter.string(from:)) ?? "fără dată")
                text += " — " + entry.subject
                if let amount = entry.amount { text += " — " + amount }
                text += "\n    de la: " + entry.sender
                text += "\n    fișier: " + (entry.files.isEmpty ? "—" : entry.files.joined(separator: ", ")) + "\n"
            }
            text += "\n"
        }
        if !servicesWithoutInvoices.isEmpty {
            text += "Nu am găsit facturi pentru: " + servicesWithoutInvoices.joined(separator: ", ") + "\n"
            text += "(Poate au venit pe alt email, pe o lună vecină, sau factura se descarcă doar din contul serviciului.)\n"
        }
        return text
    }
}
