import AppKit
import Foundation
import MackyCore

/// The user's Claude and ChatGPT conversations (and Claude projects), imported from the official data exports.
/// Kept only on this Mac, in ~/Library/Application Support/Macky/chat-archive.json.
@MainActor
final class ChatArchiveStore: ObservableObject {
    @Published private(set) var chats: [ChatArchiveKit.Chat] = []
    @Published private(set) var projects: [ChatArchiveKit.Project] = []
    @Published private(set) var importDates: [String: Date] = [:]
    @Published private(set) var isImporting = false
    @Published var statusText: String?

    private struct StoredArchive: Codable {
        var chats: [ChatArchiveKit.Chat]
        var projects: [ChatArchiveKit.Project]
        var importDates: [String: Date]
    }

    private nonisolated static let fileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("chat-archive.json")

    init() {
        Task { await load() }
    }

    var isEmpty: Bool { chats.isEmpty && projects.isEmpty }

    func chatCount(for source: ChatArchiveKit.Source) -> Int {
        chats.filter { $0.source == source }.count
    }

    // MARK: Tools

    func search(_ query: String) -> String {
        var text = ChatArchiveKit.searchResultText(ChatArchiveKit.search(query, in: chats))
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let matchingProjects = projects.filter {
            ($0.name + " " + $0.summary + " " + $0.instructions).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(folded)
        }
        if !matchingProjects.isEmpty {
            text += "\nClaude projects: " + matchingProjects.map(\.name).joined(separator: ", ")
        }
        return text
    }

    func read(title: String) -> String? {
        if let project = ChatArchiveKit.bestTitleMatch(title, in: projects, name: \.name),
           project.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            == title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
            return ChatArchiveKit.projectText(project)
        }
        if let chat = ChatArchiveKit.bestTitleMatch(title, in: chats.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }, name: \.title) {
            return ChatArchiveKit.transcript(chat)
        }
        return ChatArchiveKit.bestTitleMatch(title, in: projects, name: \.name).map { ChatArchiveKit.projectText($0) }
    }

    // MARK: Import

    /// Called with the text of Claude's own memory when an export contains it.
    var onClaudeMemory: (@MainActor (String) -> Void)?

    private struct ExportContents: Sendable {
        var chats: [ChatArchiveKit.Chat] = []
        var projects: [ChatArchiveKit.Project] = []
        var memoryText = ""
    }

    /// Accepts the export's .zip files, their unpacked folder, conversations.json / projects.json on their own,
    /// or Claude's newer export manifest (a small .json that lists one download per category).
    func importExport(from url: URL) async {
        if url.pathExtension.lowercased() == "json",
           let data = try? Data(contentsOf: url), data.count < 1_000_000,
           let files = ChatArchiveKit.parseExportManifest(data) {
            await importFromManifest(files)
            return
        }
        isImporting = true
        statusText = "Import \(url.lastPathComponent)…"
        defer { isImporting = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) { try Self.readExport(at: url) }.value
            guard !result.chats.isEmpty || !result.projects.isEmpty || !result.memoryText.isEmpty else {
                statusText = "✗ Nu am găsit conversații în \(url.lastPathComponent). Alege arhiva .zip sau fișierul .json primit de la Claude sau ChatGPT."
                return
            }
            await merge(result)
        } catch {
            statusText = "✗ Nu am putut importa: \(error.localizedDescription)"
        }
    }

    /// Opens each useful download link in the browser (where the user is logged in to Claude),
    /// then imports every .zip as soon as it lands in Downloads.
    private func importFromManifest(_ files: [ChatArchiveKit.ExportManifestFile]) async {
        let wanted = files.filter { ChatArchiveKit.usefulManifestCategories.contains($0.category) }
        guard !wanted.isEmpty else {
            statusText = "✗ Exportul nu conține conversații sau proiecte."
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        // Already downloaded ones are imported directly; the links work only once.
        var pending: [ChatArchiveKit.ExportManifestFile] = []
        for file in wanted {
            if let existing = Self.downloadedFile(named: file.filename, in: downloads, since: .distantPast) {
                await importExport(from: existing)
            } else {
                pending.append(file)
            }
        }
        guard !pending.isEmpty else { return }

        isImporting = true
        defer { isImporting = false }
        let startDate = Date().addingTimeInterval(-5)
        for file in pending { NSWorkspace.shared.open(file.url) }
        statusText = "Am deschis \(pending.count) descărcări în browser (trebuie să fii logat în Claude). Aștept să apară în Downloads…"

        var remaining = pending
        let deadline = Date().addingTimeInterval(15 * 60)
        while !remaining.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for file in remaining {
                guard let downloaded = Self.downloadedFile(named: file.filename, in: downloads, since: startDate),
                      await Self.isFinishedDownloading(downloaded) else { continue }
                remaining.removeAll { $0.filename == file.filename }
                isImporting = false
                await importExport(from: downloaded)
                isImporting = true
            }
        }
        if !remaining.isEmpty {
            statusText = "✗ Nu au apărut în Downloads: \(remaining.map(\.filename).joined(separator: ", ")). Descarcă-le din linkurile din email și importă-le aici."
        }
    }

    private func merge(_ result: ExportContents) async {
        let importedIdentifiers = Set(result.chats.map(\.id))
        chats = chats.filter { !importedIdentifiers.contains($0.id) } + result.chats
        if !result.projects.isEmpty {
            let projectIdentifiers = Set(result.projects.map(\.id))
            projects = projects.filter { !projectIdentifiers.contains($0.id) } + result.projects
        }
        for source in Set(result.chats.map(\.source)) { importDates[source.rawValue] = Date() }
        if !result.projects.isEmpty { importDates[ChatArchiveKit.Source.claude.rawValue] = Date() }
        if !result.memoryText.isEmpty { onClaudeMemory?(result.memoryText) }
        await save()
        var parts: [String] = []
        if !result.chats.isEmpty {
            let sourceNames = Set(result.chats.map(\.source.displayName)).sorted().joined(separator: " și ")
            parts.append("\(result.chats.count) conversații din \(sourceNames)")
        }
        if !result.projects.isEmpty { parts.append("\(result.projects.count) proiecte Claude") }
        if !result.memoryText.isEmpty { parts.append("memoria din Claude (adăugată în Memorie)") }
        statusText = "Am importat " + parts.joined(separator: ", ") + "."
    }

    /// "conversations-000.zip", or the browser's "conversations-000 (1).zip" when the name was taken.
    private nonisolated static func downloadedFile(named filename: String, in folder: URL, since date: Date) -> URL? {
        let base = (filename as NSString).deletingPathExtension
        let fileExtension = (filename as NSString).pathExtension
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries
            .filter { entry in
                let name = entry.lastPathComponent
                return (name == filename || (name.hasPrefix(base + " (") && name.hasSuffix(")." + fileExtension)))
            }
            .compactMap { entry -> (URL, Date)? in
                guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= date else { return nil }
                return (entry, modified)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private nonisolated static func isFinishedDownloading(_ url: URL) async -> Bool {
        func size() -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0 }
        let first = size()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return first > 0 && first == size()
    }

    func removeAll(from source: ChatArchiveKit.Source) async {
        chats.removeAll { $0.source == source }
        if source == .claude { projects = [] }
        importDates[source.rawValue] = nil
        await save()
        statusText = "Am șters conversațiile din \(source.displayName)."
    }

    /// Saves a Claude project as a skill in Macky's skills folder, so it can be used by name (and later by agents).
    @discardableResult
    func makeSkill(from project: ChatArchiveKit.Project, in skillsFolder: URL) -> Bool {
        let folderName = project.name.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-")
        let folder = skillsFolder.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ChatArchiveKit.skillMarkdown(for: project).write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            statusText = "Skill-ul „\(project.name)” e gata."
            return true
        } catch {
            statusText = "✗ Nu am putut salva skill-ul: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Files

    private nonisolated static func readExport(at url: URL) throws -> ExportContents {
        let fileManager = FileManager.default
        var folder = url
        var temporaryFolder: URL?
        defer { if let temporaryFolder { try? fileManager.removeItem(at: temporaryFolder) } }

        if url.pathExtension.lowercased() == "json" {
            var contents = ExportContents()
            read(fileAt: url, category: category(of: url), into: &contents)
            return contents
        }
        if url.pathExtension.lowercased() == "zip" {
            let destination = fileManager.temporaryDirectory.appendingPathComponent("macky-export-\(UUID().uuidString)", isDirectory: true)
            temporaryFolder = destination
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", url.path, destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            folder = destination
        }

        // The archive's own name tells what is inside (conversations-000.zip, projects-000.zip, memories-000.zip).
        let archiveCategory = category(of: url)
        var contents = ExportContents()
        let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let fileURL = enumerator?.nextObject() as? URL {
            let fileExtension = fileURL.pathExtension.lowercased()
            if fileExtension == "zip" {
                // An export downloaded as one archive with the category archives inside.
                if let inner = try? readExport(at: fileURL) {
                    contents.chats += inner.chats
                    contents.projects += inner.projects
                    contents.memoryText += inner.memoryText
                }
                continue
            }
            guard ["json", "md", "txt"].contains(fileExtension) else { continue }
            read(fileAt: fileURL, category: category(of: fileURL) ?? archiveCategory, into: &contents)
        }
        return contents
    }

    private nonisolated static func category(of url: URL) -> String? {
        let path = url.path.lowercased()
        for category in ["conversations", "projects", "memories"] where url.lastPathComponent.lowercased().hasPrefix(category) {
            return category
        }
        if path.contains("/conversations") { return "conversations" }
        if path.contains("/projects") { return "projects" }
        if path.contains("/memories") || path.contains("/memory") { return "memories" }
        return nil
    }

    private nonisolated static func read(fileAt fileURL: URL, category: String?, into contents: inout ExportContents) {
        let name = fileURL.lastPathComponent.lowercased()
        // Skip what the export also contains but Macky has no use for.
        if name.hasPrefix("users") || name.hasPrefix("light_metadata") || name.hasPrefix("frames") || name.hasPrefix("design_chats") { return }
        let fileExtension = fileURL.pathExtension.lowercased()
        if category == "memories" {
            if fileExtension == "json", let data = try? Data(contentsOf: fileURL), let object = try? JSONSerialization.jsonObject(with: data) {
                contents.memoryText += memoryStrings(in: object).joined(separator: "\n")
            } else if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                contents.memoryText += text
            }
            return
        }
        guard fileExtension == "json", let data = try? Data(contentsOf: fileURL) else { return }
        if category == "projects" {
            contents.projects += (try? ChatArchiveKit.parseClaudeProjects(data)) ?? []
            return
        }
        if let chats = try? ChatArchiveKit.parseConversations(data), !chats.isEmpty {
            contents.chats += chats
        } else if category == nil, name.hasPrefix("projects") {
            contents.projects += (try? ChatArchiveKit.parseClaudeProjects(data)) ?? []
        }
    }

    /// The readable text of a memory export, whatever its exact shape.
    private nonisolated static func memoryStrings(in object: Any) -> [String] {
        if let string = object as? String {
            return string.count >= 20 ? [string] : []
        }
        if let array = object as? [Any] { return array.flatMap(memoryStrings) }
        if let dictionary = object as? [String: Any] {
            let preferredKeys = ["content", "memory", "text", "summary", "conversations_memory", "project_memories"]
            let preferred = preferredKeys.compactMap { dictionary[$0] }.flatMap(memoryStrings)
            return preferred.isEmpty ? dictionary.values.flatMap(memoryStrings) : preferred
        }
        return []
    }

    private func load() async {
        let stored = await Task.detached(priority: .utility) { () -> StoredArchive? in
            guard let data = try? Data(contentsOf: Self.fileURL) else { return nil }
            return try? JSONDecoder().decode(StoredArchive.self, from: data)
        }.value
        guard let stored else { return }
        chats = stored.chats
        projects = stored.projects
        importDates = stored.importDates
    }

    private func save() async {
        let archive = StoredArchive(chats: chats, projects: projects, importDates: importDates)
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(archive) else { return }
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: [.atomic])
        }.value
    }
}
