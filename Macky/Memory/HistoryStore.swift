import Foundation
import MackyCore

/// Every request and what Macky answered or did, newest first. Stored as one JSON object per line
/// in ~/Library/Application Support/Macky/history.jsonl, so saving a new entry only appends a line.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let settings: AppSettings
    private let fileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("history.jsonl")
    private static let maximumEntries = 5000

    init(settings: AppSettings) {
        self.settings = settings
        load()
    }

    func record(_ entry: HistoryEntry) {
        guard settings.historyEnabled else { return }
        entries.insert(entry, at: 0)
        guard let line = Self.encodedLine(for: entry) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL, options: .atomic)
        }
        if entries.count > Self.maximumEntries + 500 {
            entries = Array(entries.prefix(Self.maximumEntries))
            rewriteFile()
        }
    }

    func delete(_ identifier: UUID) {
        entries.removeAll { $0.id == identifier }
        rewriteFile()
    }

    func deleteAll() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = text.split(separator: "\n")
            .compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
            .sorted { $0.date > $1.date }
        if entries.count > Self.maximumEntries {
            entries = Array(entries.prefix(Self.maximumEntries))
            rewriteFile()
        }
    }

    private func rewriteFile() {
        var data = Data()
        for entry in entries.reversed() {
            if let line = Self.encodedLine(for: entry) { data.append(line) }
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func encodedLine(for entry: HistoryEntry) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return nil }
        line.append(0x0A)
        return line
    }
}
