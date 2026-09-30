import AppKit
import Foundation
import PDFKit

/// Finds files on the Mac with Spotlight, by name and content, newest first.
@MainActor
final class LocalFileSearch {
    private var activeQuery: NSMetadataQuery?

    func search(_ query: String, kind: String, maximumResults: Int = 15) async -> String {
        let words = query.components(separatedBy: .whitespacesAndNewlines).filter { $0.count >= 2 }
        guard !words.isEmpty else { return "Empty search." }
        var predicates = words.map { word -> NSPredicate in
            let pattern = "*\(word)*"
            return NSPredicate(format: "kMDItemFSName ==[cd] %@ || kMDItemTextContent ==[cd] %@", pattern, pattern)
        }
        if let contentTypes = Self.contentTypes(forKind: kind) {
            predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: contentTypes.map {
                NSPredicate(format: "kMDItemContentTypeTree == %@", $0)
            }))
        }

        let metadataQuery = NSMetadataQuery()
        metadataQuery.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        metadataQuery.searchScopes = [NSMetadataQueryUserHomeScope]
        metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        activeQuery = metadataQuery

        let finished: Bool = await withCheckedContinuation { continuation in
            let waiter = QueryWaiter(continuation)
            waiter.observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: metadataQuery, queue: .main) { _ in
                waiter.finish(true)
            }
            metadataQuery.start()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                waiter.finish(false)
            }
        }
        metadataQuery.stop()
        activeQuery = nil

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var lines: [String] = []
        for index in 0..<metadataQuery.resultCount {
            guard let item = metadataQuery.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/"), !path.contains("/."), !path.contains("/node_modules/") else { continue }
            let date = (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date).map { formatter.string(from: $0) } ?? ""
            lines.append("\(path) | modified \(date)")
            if lines.count >= maximumResults { break }
        }
        if lines.isEmpty { return finished ? "No files match \"\(query)\"." : "The search took too long; try more specific words." }
        return lines.joined(separator: "\n")
    }

    private static func contentTypes(forKind kind: String) -> [String]? {
        switch kind {
        case "pdf": return ["com.adobe.pdf"]
        case "spreadsheet": return ["public.spreadsheet", "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "public.comma-separated-values-text"]
        case "presentation": return ["public.presentation"]
        case "image": return ["public.image"]
        case "folder": return ["public.folder"]
        case "document": return ["public.text", "public.composite-content", "com.adobe.pdf", "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc"]
        default: return nil
        }
    }
}

/// Resumes the Spotlight wait once: when gathering finishes or on timeout, whichever comes first.
private final class QueryWaiter: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    var observer: NSObjectProtocol?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ finished: Bool) {
        lock.lock()
        let pendingContinuation = continuation
        continuation = nil
        let pendingObserver = observer
        observer = nil
        lock.unlock()
        if let pendingObserver { NotificationCenter.default.removeObserver(pendingObserver) }
        pendingContinuation?.resume(returning: finished)
    }
}

/// Reads the text of common document types: PDF, Word, RTF, HTML, plain text, CSV, Markdown.
enum FileTextReader {
    static func readText(at url: URL, maximumCharacters: Int = 12_000) -> String {
        let fileExtension = url.pathExtension.lowercased()
        var text: String?
        if fileExtension == "pdf" {
            text = PDFDocument(url: url)?.string
        } else if ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive"].contains(fileExtension) {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        if text == nil {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "This file has no readable text (Macky reads PDF, Word, RTF, HTML and text files)."
        }
        return text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) + "\n[…truncated]" : text
    }

    /// Reads a local file the model asked for; only regular files the user can read.
    static func readLocalFile(atPath path: String) -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else { return "No file at \(path)." }
        if isDirectory.boolValue {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: expandedPath)) ?? []
            return "Folder with \(entries.count) items: " + entries.filter { !$0.hasPrefix(".") }.prefix(60).joined(separator: ", ")
        }
        return readText(at: URL(fileURLWithPath: expandedPath))
    }
}
