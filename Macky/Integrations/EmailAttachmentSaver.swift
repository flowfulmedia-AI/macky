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

    /// What happened to one email.
    struct SavedEmail {
        var identifier: String
        var email: ParsedEmail?
        var files: [String] = []
        var amount: String?
        var error: String?
        /// Found by the search but not a bill (newsletter, someone mentioning the service…): nothing saved.
        var wasRejected = false
    }

    /// For invoices: which emails count and what their files are called.
    struct InvoiceRules {
        var accepts: (ParsedEmail) -> Bool
        var fileName: (ParsedEmail) -> String
    }

    /// A report for the model: what was saved where, and which emails failed.
    func save(identifiers: [String], folder requestedFolder: String, savesEmailWithoutAttachment: Bool,
              progress: (String) -> Void) async -> String {
        let folderURL: URL
        do {
            folderURL = try makeFolder(requestedFolder)
        } catch {
            return "Could not create the folder: \(error.localizedDescription)"
        }
        let results = await saveEmails(identifiers, into: folderURL, savesEmailWithoutAttachment: savesEmailWithoutAttachment, progress: progress)
        let saved = results.filter { $0.error == nil && !$0.files.isEmpty }
        let failed = results.filter { $0.error != nil }
        var report = "Folder: \(folderURL.path)\nSaved \(saved.flatMap(\.files).count) file(s):\n"
            + saved.map { "- " + $0.files.joined(separator: ", ") + " — from \"\($0.email?.subject ?? "")\"" }.joined(separator: "\n")
        let skipped = results.filter { $0.error == nil && $0.files.isEmpty }
        if !skipped.isEmpty { report += "\nSkipped (no attachment): " + skipped.compactMap { $0.email?.subject }.joined(separator: "; ") }
        if !failed.isEmpty { report += "\nFailed:\n" + failed.map { "- \($0.identifier): \($0.error ?? "")" }.joined(separator: "\n") }
        return report
    }

    /// The monthly invoices: one search per service in every account, everything saved, plus a summary file.
    func collectInvoices(services: [String], month: String, folder requestedFolder: String, fileNameTemplate: String?,
                         progress: (String) -> Void) async -> String {
        guard let period = InvoiceKit.monthRange(month) else {
            return "Could not understand the month \"\(month)\"; use the form 2026-09."
        }
        let folderURL: URL
        do {
            folderURL = try makeFolder(requestedFolder)
        } catch {
            return "Could not create the folder: \(error.localizedDescription)"
        }
        ActivityLog.note("Facturi: \(services.count) servicii, \(month), folder \(folderURL.path)")

        var identifiersByService: [(service: String, identifiers: [String])] = []
        var seen = Set<String>()
        var searchProblems: [String] = []
        for (index, service) in services.enumerated() {
            progress("Caut facturile \(service)… \(index + 1)/\(services.count)")
            let query = InvoiceKit.query(service: service, start: period.start, end: period.end)
            var lines = await googleAccountManager.searchGmailLines(query: query, maximumResults: 15, accountFilter: nil)
            lines += await mailAccountsStore.search(query: query, maximumResults: 15, accountFilter: nil)
            searchProblems += lines.filter { $0.contains("search failed") }
            let identifiers = InvoiceKit.identifiers(inSearchLines: lines).filter { seen.insert($0).inserted }
            identifiersByService.append((service, identifiers))
        }

        var entries: [InvoiceKit.SummaryEntry] = []
        var failures: [String] = []
        var rejected = 0
        let total = identifiersByService.reduce(0) { $0 + $1.identifiers.count }
        var done = 0
        for (service, identifiers) in identifiersByService where !identifiers.isEmpty {
            let profile = InvoiceKit.profile(for: service)
            let template = fileNameTemplate ?? InvoiceKit.defaultFileNameTemplate
            let rules = InvoiceRules(
                accepts: { email in
                    InvoiceKit.isInvoice(from: email.from, subject: email.subject, attachmentNames: email.attachments.filter(\.isDocument).map(\.fileName),
                                         text: HTMLTextExtractor.readableText(fromHTML: email.html), profile: profile)
                },
                fileName: { email in
                    InvoiceKit.fileName(template: template, service: profile.displayName, date: email.date ?? period.start)
                }
            )
            let results = await saveEmails(identifiers, into: folderURL, savesEmailWithoutAttachment: true, invoiceRules: rules) { _ in
                done += 1
                progress("Verific și salvez facturile… \(min(done, total))/\(total)")
            }
            for result in results {
                if let error = result.error {
                    failures.append("\(service): \(error)")
                } else if result.wasRejected {
                    rejected += 1
                } else if let email = result.email {
                    entries.append(InvoiceKit.SummaryEntry(service: service, date: email.date, subject: email.subject,
                                                           sender: email.from, amount: result.amount, files: result.files))
                }
            }
        }

        let missing = services.filter { service in !entries.contains { $0.service == service } }
        let title = folderURL.lastPathComponent
        let summary = InvoiceKit.summary(title: title, entries: entries, servicesWithoutInvoices: missing)
        let summaryName = write(Data(summary.utf8), named: "Rezumat facturi.txt", in: folderURL)
        ActivityLog.note("Facturi salvate: \(entries.count), respinse: \(rejected), lipsă: \(missing.joined(separator: ", "))")

        var report = "Folder: \(folderURL.path)\nSaved \(entries.flatMap(\.files).count) file(s) from \(entries.count) email(s); summary file: \(summaryName).\n"
        report += entries.map { "- \($0.service): \($0.subject)\($0.amount.map { " — " + $0 } ?? "") → \($0.files.joined(separator: ", "))" }.joined(separator: "\n")
        if rejected > 0 { report += "\nSkipped \(rejected) email(s) that matched the search but are not bills from these services." }
        if !missing.isEmpty { report += "\nNo invoice found for: " + missing.joined(separator: ", ") }
        if !failures.isEmpty { report += "\nFailed: " + failures.joined(separator: "; ") }
        if !searchProblems.isEmpty { report += "\nSearch problems: " + searchProblems.joined(separator: "; ") }
        return report
    }

    private func makeFolder(_ requestedFolder: String) throws -> URL {
        let folderPath = EmailFiles.folderPath(for: requestedFolder, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            ErrorLogStore.shared.record("Atașamente email", "Nu am putut crea folderul \(folderPath): \(error.localizedDescription)")
            throw error
        }
        return folderURL
    }

    private func saveEmails(_ identifiers: [String], into folderURL: URL, savesEmailWithoutAttachment: Bool,
                            invoiceRules: InvoiceRules? = nil, progress: (String) -> Void) async -> [SavedEmail] {
        var results: [SavedEmail] = []
        for (index, identifier) in identifiers.enumerated() {
            progress("Descarc atașamentele… \(index + 1)/\(identifiers.count)")
            var result = SavedEmail(identifier: identifier)
            do {
                let raw: Data
                if identifier.hasPrefix("imap:") {
                    raw = try await mailAccountsStore.rawMessage(identifier: identifier)
                } else {
                    raw = try await googleAccountManager.rawEmail(identifier: identifier)
                }
                let email = EmailFiles.parse(rawMessage: raw)
                result.email = email
                if let invoiceRules, !invoiceRules.accepts(email) {
                    result.wasRejected = true
                    ActivityLog.note("Nu e factură, sărit: \(email.from) — \(email.subject)")
                    results.append(result)
                    continue
                }
                result.amount = InvoiceKit.amount(in: HTMLTextExtractor.readableText(fromHTML: email.html))
                // Invoices: PDFs first (a receipt email often also carries a logo or a calendar file).
                var documents = email.attachments.filter(\.isDocument)
                if invoiceRules != nil, documents.contains(where: { $0.mimeType == "application/pdf" || $0.fileName.lowercased().hasSuffix(".pdf") }) {
                    documents = documents.filter { $0.mimeType == "application/pdf" || $0.fileName.lowercased().hasSuffix(".pdf") }
                }
                if documents.isEmpty {
                    if savesEmailWithoutAttachment {
                        let pdf = try await Self.pdf(fromHTML: email.html)
                        let name = invoiceRules.map { $0.fileName(email) + ".pdf" } ?? EmailFiles.documentName(for: email)
                        result.files.append(write(pdf, named: name, in: folderURL))
                    }
                } else {
                    for attachment in documents {
                        var name = EmailFiles.safeFileName(attachment.fileName)
                        if let invoiceRules {
                            let fileExtension = (attachment.fileName as NSString).pathExtension
                            name = invoiceRules.fileName(email) + (fileExtension.isEmpty ? ".pdf" : "." + fileExtension.lowercased())
                        }
                        result.files.append(write(attachment.data, named: name, in: folderURL))
                    }
                }
            } catch {
                let message = CompanionSession.userFacingMessage(for: error)
                result.error = message
                ErrorLogStore.shared.record("Atașamente email", "Nu am putut salva emailul \(identifier): \(message)")
            }
            results.append(result)
        }
        return results
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
