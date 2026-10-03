import AppKit
import Foundation
import MackyCore
import WebKit

/// Saves emails' attachments (invoices, contracts…) from every connected account into a folder on the Mac.
/// An email without a real attachment, like a receipt written in the email itself, is kept as a PDF of the email.
@MainActor
final class EmailAttachmentSaver {
    private let googleAccountManager: GoogleAccountManager
    private let mailAccountsStore: MailAccountsStore

    init(googleAccountManager: GoogleAccountManager, mailAccountsStore: MailAccountsStore) {
        self.googleAccountManager = googleAccountManager
        self.mailAccountsStore = mailAccountsStore
    }

    /// A report for the model: what was saved where, and which emails failed.
    func save(identifiers: [String], folder requestedFolder: String, savesEmailWithoutAttachment: Bool,
              progress: (String) -> Void) async -> String {
        let folderPath = EmailFiles.folderPath(for: requestedFolder, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            ErrorLogStore.shared.record("Atașamente email", "Nu am putut crea folderul \(folderPath): \(error.localizedDescription)")
            return "Could not create the folder \(folderPath): \(error.localizedDescription)"
        }

        var savedLines: [String] = []
        var failedLines: [String] = []
        var skippedLines: [String] = []
        for (index, identifier) in identifiers.enumerated() {
            progress("Descarc atașamentele… \(index + 1)/\(identifiers.count)")
            do {
                let raw: Data
                if identifier.hasPrefix("imap:") {
                    raw = try await mailAccountsStore.rawMessage(identifier: identifier)
                } else {
                    raw = try await googleAccountManager.rawEmail(identifier: identifier)
                }
                let email = EmailFiles.parse(rawMessage: raw)
                let documents = email.attachments.filter(\.isDocument)
                if documents.isEmpty {
                    guard savesEmailWithoutAttachment else {
                        skippedLines.append("\(email.subject) (no attachment)")
                        continue
                    }
                    let pdf = try await Self.pdf(fromHTML: email.html)
                    let name = write(pdf, named: EmailFiles.documentName(for: email), in: folderURL)
                    savedLines.append("\(name) — the email itself, as PDF (\(email.subject))")
                } else {
                    for attachment in documents {
                        let name = write(attachment.data, named: EmailFiles.safeFileName(attachment.fileName), in: folderURL)
                        savedLines.append("\(name) — from \"\(email.subject)\"")
                    }
                }
            } catch {
                let message = CompanionSession.userFacingMessage(for: error)
                failedLines.append("\(identifier): \(message)")
                ErrorLogStore.shared.record("Atașamente email", "Nu am putut salva emailul \(identifier): \(message)")
            }
        }

        var report = "Folder: \(folderPath)\nSaved \(savedLines.count) file(s):\n" + savedLines.map { "- " + $0 }.joined(separator: "\n")
        if !skippedLines.isEmpty { report += "\nSkipped (no attachment):\n" + skippedLines.map { "- " + $0 }.joined(separator: "\n") }
        if !failedLines.isEmpty { report += "\nFailed:\n" + failedLines.map { "- " + $0 }.joined(separator: "\n") }
        return report
    }

    private func write(_ data: Data, named name: String, in folderURL: URL) -> String {
        let unique = EmailFiles.uniqueFileName(name) { FileManager.default.fileExists(atPath: folderURL.appendingPathComponent($0).path) }
        try? data.write(to: folderURL.appendingPathComponent(unique), options: .atomic)
        return unique
    }

    // MARK: Email → PDF

    private static func pdf(fromHTML html: String) async throws -> Data {
        let renderer = HTMLPDFRenderer()
        return try await renderer.render(html)
    }
}

/// Lays an email's HTML out off screen and prints it to a PDF (A4 width, as tall as the email).
@MainActor
private final class HTMLPDFRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    func render(_ html: String) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        defer { self.webView = nil }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
            // Remote images may never finish loading; the text is what matters.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(nil) }
        }
        let height = (try? await webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") as? Double) ?? 1123
        webView.frame = NSRect(x: 0, y: 0, width: 794, height: max(1123, min(height, 20_000)))
        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = webView.bounds
        return try await webView.pdf(configuration: pdfConfiguration)
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }
}
