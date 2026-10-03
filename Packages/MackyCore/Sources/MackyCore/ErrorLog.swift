import Foundation

/// One problem Macky ran into, kept so the user (and Macky itself) can see later what went wrong and where.
public struct ErrorLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    /// Where it happened, in Romanian: "Agent Romeo", "Comandă", "Email", "Închidere neașteptată"…
    public var source: String
    public var message: String
    /// Technical detail for debugging (a crash's stack, the request that failed); may be empty.
    public var details: String

    public init(id: UUID = UUID(), date: Date = Date(), source: String, message: String, details: String = "") {
        self.id = id
        self.date = date
        self.source = source
        self.message = message
        self.details = details
    }
}

public struct ErrorLog: Codable, Equatable, Sendable {
    public private(set) var entries: [ErrorLogEntry] = []
    public static let maximumEntries = 300

    public init(entries: [ErrorLogEntry] = []) {
        self.entries = entries
    }

    /// Newest first. The same error repeated within a minute is kept once.
    public mutating func add(_ entry: ErrorLogEntry) {
        if let latest = entries.first, latest.source == entry.source, latest.message == entry.message,
           abs(entry.date.timeIntervalSince(latest.date)) < 60 {
            return
        }
        entries.insert(entry, at: 0)
        entries.sort { $0.date > $1.date }
        if entries.count > Self.maximumEntries { entries.removeLast(entries.count - Self.maximumEntries) }
    }

    public mutating func removeAll() {
        entries = []
    }

    /// Plain text of the whole log, for copying into a message.
    public func plainText(limit: Int = maximumEntries) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return entries.prefix(limit).map { entry in
            var line = "[\(formatter.string(from: entry.date))] \(entry.source): \(entry.message)"
            if !entry.details.isEmpty { line += "\n" + entry.details }
            return line
        }.joined(separator: "\n\n")
    }
}

/// Reads the crash reports macOS writes (~/Library/Logs/DiagnosticReports/Macky-….ips): a JSON header line,
/// then a JSON body with the exception and every thread's stack.
public enum CrashReportParser {
    public struct Summary: Equatable, Sendable {
        public var date: Date?
        public var reason: String
        public var details: String
    }

    public static func summary(of report: String) -> Summary? {
        let normalized = report.replacingOccurrences(of: "\r\n", with: "\n")
        guard let newline = normalized.firstIndex(of: "\n") else { return nil }
        let headerText = String(normalized[..<newline])
        let bodyText = String(normalized[normalized.index(after: newline)...])
        let header = (try? JSONSerialization.jsonObject(with: Data(headerText.utf8))) as? [String: Any] ?? [:]
        guard let body = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any] else { return nil }

        var date: Date?
        if let timestamp = (header["timestamp"] as? String) ?? (body["captureTime"] as? String) {
            date = parseDate(timestamp)
        }

        var reasonParts: [String] = []
        if let exception = body["exception"] as? [String: Any] {
            reasonParts += [exception["type"] as? String, exception["signal"] as? String, exception["subtype"] as? String].compactMap { $0 }
        }
        if let termination = body["termination"] as? [String: Any], let indicator = termination["indicator"] as? String {
            reasonParts.append(indicator)
        }
        var details: [String] = []
        if let diagnostic = body["asi"] as? [String: Any] {
            // "Application Specific Information": Swift's own message, e.g. "Fatal error: Index out of range".
            for value in diagnostic.values {
                if let lines = value as? [String] { details += lines }
            }
        }
        if let crashed = crashedThreadFrames(body) {
            details.append("Firul care s-a oprit:")
            details += crashed
        }
        let reason = reasonParts.isEmpty ? "Macky s-a închis neașteptat." : reasonParts.joined(separator: " · ")
        return Summary(date: date, reason: reason, details: details.joined(separator: "\n"))
    }

    /// The crashed thread's frames as "Image  symbol", most useful first, without the system's noise at the bottom.
    static func crashedThreadFrames(_ body: [String: Any], limit: Int = 25) -> [String]? {
        guard let threads = body["threads"] as? [[String: Any]] else { return nil }
        let index = (body["faultingThread"] as? Int) ?? threads.firstIndex { ($0["triggered"] as? Bool) == true }
        guard let index, threads.indices.contains(index), let frames = threads[index]["frames"] as? [[String: Any]] else { return nil }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        return frames.prefix(limit).map { frame in
            let imageIndex = frame["imageIndex"] as? Int
            let imageName = imageIndex.flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
            let symbol = (frame["symbol"] as? String) ?? "0x" + String((frame["imageOffset"] as? Int) ?? 0, radix: 16)
            var line = "  \(imageName)  \(symbol)"
            if let file = frame["sourceFile"] as? String, let lineNumber = frame["sourceLine"] as? Int {
                line += "  (\(file):\(lineNumber))"
            }
            return line
        }
    }

    /// "2026-10-03 07:00:12.00 +0300"
    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss.SSSS Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
