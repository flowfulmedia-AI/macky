import Foundation

/// The monthly "collect every invoice" job, done in one go: one search per service across every email account,
/// then every invoice saved into one folder with a summary file.
public enum InvoiceKit {
    /// Words that mark a bill, in English and Romanian.
    static let invoiceWords = ["invoice", "receipt", "factura", "factură", "chitanta", "chitanță", "bon", "payment", "plata", "plată",
                               "billing", "subscription", "abonament", "renewal", "charged", "comanda", "order"]

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

    /// One Gmail-syntax search for one service's bills in a period (IMAP accounts get it translated).
    public static func query(service: String, start: Date, end: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let senders = aliases(for: service).flatMap { alias -> [String] in
            let word = alias.lowercased()
            return word.contains(" ") ? ["\"\(word)\""] : ["from:\(word)", "subject:\(word)"]
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy/MM/dd"
        return "{" + senders.joined(separator: " ") + "} {" + invoiceWords.joined(separator: " ") + "} after:"
            + formatter.string(from: start) + " before:" + formatter.string(from: end)
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
