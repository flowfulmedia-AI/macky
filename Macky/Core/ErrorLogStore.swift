import AppKit
import Foundation
import MackyCore

/// Every error Macky runs into, in one place (Home → Erori), saved in ~/Library/Application Support/Macky/errors.json.
/// Crash reports macOS wrote for Macky are read at launch, so a sudden quit shows up here with its cause.
@MainActor
final class ErrorLogStore: ObservableObject {
    static let shared = ErrorLogStore()

    @Published private(set) var log = ErrorLog()

    private let fileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("errors.json")
    private static let importedCrashesKey = "errorLogImportedCrashReports"

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let saved = try? decoder.decode(ErrorLog.self, from: data) {
            log = saved
        }
    }

    var entries: [ErrorLogEntry] { log.entries }

    func record(_ source: String, _ message: String, details: String = "") {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.add(ErrorLogEntry(source: source, message: trimmed, details: details))
        save()
    }

    /// Callable from any thread.
    nonisolated static func report(_ source: String, _ message: String, details: String = "") {
        Task { @MainActor in shared.record(source, message, details: details) }
    }

    func clear() {
        log.removeAll()
        save()
    }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.plainText(), forType: .string)
    }

    /// Recent entries as text for the assistant ("de ce a dat eroare?").
    func summaryForAssistant(limit: Int = 15) -> String {
        log.entries.isEmpty ? "The error log is empty." : log.plainText(limit: limit)
    }

    // MARK: Crash reports

    func importCrashReports() {
        let folders = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports/Retired", isDirectory: true)
        ]
        var imported = Set(UserDefaults.standard.stringArray(forKey: Self.importedCrashesKey) ?? [])
        let isFirstImport = UserDefaults.standard.object(forKey: Self.importedCrashesKey) == nil
        let twoWeeksAgo = Date().addingTimeInterval(-14 * 86_400)
        var added = false
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.lastPathComponent.hasPrefix("Macky") && ["ips", "crash"].contains(file.pathExtension) {
                guard !imported.contains(file.lastPathComponent) else { continue }
                imported.insert(file.lastPathComponent)
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                // The first time, only recent crashes are worth showing.
                guard !isFirstImport || modified > twoWeeksAgo,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let summary = CrashReportParser.summary(of: text)
                log.add(ErrorLogEntry(
                    date: summary?.date ?? modified,
                    source: "Închidere neașteptată",
                    message: "Macky s-a închis singur. " + (summary?.reason ?? ""),
                    details: (summary?.details ?? "") + "\nRaport: \(file.path)"
                ))
                added = true
            }
        }
        UserDefaults.standard.set(Array(imported), forKey: Self.importedCrashesKey)
        if added { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
