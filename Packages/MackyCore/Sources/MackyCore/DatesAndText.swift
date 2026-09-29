import Foundation

public struct CalendarEventRequest: Equatable, Sendable {
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?

    public init(title: String, startDate: Date, endDate: Date, isAllDay: Bool, location: String?, notes: String?) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }
}

/// Reads the dates models write: ISO 8601 with or without seconds / time zone; plain dates count as midnight.
/// Dates without a time zone are the user's local time.
public enum FlexibleDateParser {
    public static func date(from text: String?, timeZone: TimeZone = .current) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }

        let internetFormatter = ISO8601DateFormatter()
        internetFormatter.formatOptions = [.withInternetDateTime]
        if let date = internetFormatter.date(from: text) { return date }
        internetFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = internetFormatter.date(from: text) { return date }

        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            localFormatter.dateFormat = format
            if let date = localFormatter.date(from: text) { return date }
        }
        return nil
    }

    /// "joi 2 oct, 15:00" — in Romanian, for confirmations and summaries.
    public static func shortDescription(of date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ro_RO")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }

    /// Given to the model so it can turn "mâine la 3" into a real date.
    public static func currentDateContext(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE yyyy-MM-dd'T'HH:mm"
        return "Current local date and time: \(formatter.string(from: now)) (time zone \(timeZone.identifier))."
    }
}

/// Turns an HTML page into readable text for the background agent.
public enum HTMLTextExtractor {
    public static func readableText(fromHTML html: String, maximumCharacters: Int = 15_000) -> String {
        var text = html
        // Drop things that are never content.
        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer", "form"] {
            text = text.replacingOccurrences(of: "(?is)<\(tag)\\b.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        // Keep structure: block elements become line breaks.
        text = text.replacingOccurrences(of: "(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\\b[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) + "\n[…]" : text
    }

    /// Safe file name for save_file: no folders, no hidden files, Markdown by default.
    public static func sanitizedFileName(_ requestedName: String) -> String {
        var name = requestedName.components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? requestedName
        name = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty { name = "rezultat" }
        if !name.contains(".") { name += ".md" }
        return String(name.prefix(100))
    }
}
