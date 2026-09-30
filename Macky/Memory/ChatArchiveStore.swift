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

    /// Accepts the export's .zip, its unpacked folder, or conversations.json / projects.json on their own.
    func importExport(from url: URL) async {
        isImporting = true
        statusText = "Import…"
        defer { isImporting = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) { try Self.readExport(at: url) }.value
            guard !result.chats.isEmpty || !result.projects.isEmpty else {
                statusText = "✗ Nu am găsit conversații în \(url.lastPathComponent). Alege arhiva .zip primită pe email de la Claude sau ChatGPT."
                return
            }
            let importedIdentifiers = Set(result.chats.map(\.id))
            chats = chats.filter { !importedIdentifiers.contains($0.id) } + result.chats
            if !result.projects.isEmpty {
                let projectIdentifiers = Set(result.projects.map(\.id))
                projects = projects.filter { !projectIdentifiers.contains($0.id) } + result.projects
            }
            for source in Set(result.chats.map(\.source)) { importDates[source.rawValue] = Date() }
            if !result.projects.isEmpty { importDates[ChatArchiveKit.Source.claude.rawValue] = Date() }
            await save()
            let sourceNames = Set(result.chats.map(\.source.displayName)).sorted().joined(separator: " și ")
            statusText = "Am importat \(result.chats.count) conversații" + (sourceNames.isEmpty ? "" : " din \(sourceNames)")
                + (result.projects.isEmpty ? "." : " și \(result.projects.count) proiecte Claude.")
        } catch {
            statusText = "✗ Nu am putut importa: \(error.localizedDescription)"
        }
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

    private nonisolated static func readExport(at url: URL) throws -> (chats: [ChatArchiveKit.Chat], projects: [ChatArchiveKit.Project]) {
        let fileManager = FileManager.default
        var folder = url
        var temporaryFolder: URL?
        defer { if let temporaryFolder { try? fileManager.removeItem(at: temporaryFolder) } }

        if url.pathExtension.lowercased() == "json" {
            let data = try Data(contentsOf: url)
            if url.lastPathComponent.lowercased().hasPrefix("projects") {
                return ([], try ChatArchiveKit.parseClaudeProjects(data))
            }
            return (try ChatArchiveKit.parseConversations(data), [])
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

        var chats: [ChatArchiveKit.Chat] = []
        var projects: [ChatArchiveKit.Project] = []
        let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let fileURL = enumerator?.nextObject() as? URL {
            let name = fileURL.lastPathComponent.lowercased()
            // ChatGPT splits big exports into conversations-000.json, conversations-001.json…
            if name.hasPrefix("conversations") && name.hasSuffix(".json") {
                chats += (try? ChatArchiveKit.parseConversations(Data(contentsOf: fileURL))) ?? []
            } else if name == "projects.json" {
                projects += (try? ChatArchiveKit.parseClaudeProjects(Data(contentsOf: fileURL))) ?? []
            }
        }
        return (chats, projects)
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
