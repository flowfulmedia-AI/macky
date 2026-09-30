import Foundation

/// The user's past conversations from Claude and ChatGPT, imported from their data exports
/// (Claude: Settings → Privacy → Export data; ChatGPT: Settings → Data controls → Export data).
/// Neither service offers an API to read an account's chats, so the export is the official way in.
public enum ChatArchiveKit {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case claude
        case chatGPT = "chatgpt"

        public var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .chatGPT: return "ChatGPT"
            }
        }
    }

    public struct Message: Codable, Equatable, Sendable {
        public var isFromUser: Bool
        public var text: String

        public init(isFromUser: Bool, text: String) {
            self.isFromUser = isFromUser
            self.text = text
        }
    }

    public struct Chat: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var source: Source
        public var title: String
        public var date: Date?
        public var messages: [Message]

        public init(id: String, source: Source, title: String, date: Date?, messages: [Message]) {
            self.id = id
            self.source = source
            self.title = title
            self.date = date
            self.messages = messages
        }
    }

    /// A Claude project: its instructions and knowledge files. A good start for a skill or an agent.
    public struct Project: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var summary: String
        public var instructions: String
        public var documents: [Document]

        public struct Document: Codable, Equatable, Sendable {
            public var name: String
            public var text: String

            public init(name: String, text: String) {
                self.name = name
                self.text = text
            }
        }

        public init(id: String, name: String, summary: String, instructions: String, documents: [Document]) {
            self.id = id
            self.name = name
            self.summary = summary
            self.instructions = instructions
            self.documents = documents
        }
    }

    public enum ParseError: Error, Equatable {
        case notAnExport
    }

    // MARK: Parsing

    /// Reads a `conversations.json` from either service; the format is recognized from its content.
    public static func parseConversations(_ data: Data) throws -> [Chat] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ParseError.notAnExport }
        if list.isEmpty { return [] }
        if list.contains(where: { $0["mapping"] != nil }) { return list.compactMap(chatGPTChat) }
        if list.contains(where: { $0["chat_messages"] != nil }) { return list.compactMap(claudeChat) }
        throw ParseError.notAnExport
    }

    /// Reads Claude's `projects.json`.
    public static func parseClaudeProjects(_ data: Data) throws -> [Project] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ParseError.notAnExport }
        return list.compactMap { entry in
            guard let name = nonEmpty(entry["name"]) else { return nil }
            let documents = (entry["docs"] as? [[String: Any]] ?? []).compactMap { document -> Project.Document? in
                guard let text = nonEmpty(document["content"]) else { return nil }
                return Project.Document(name: nonEmpty(document["filename"]) ?? "document", text: text)
            }
            return Project(
                id: nonEmpty(entry["uuid"]) ?? name,
                name: name,
                summary: nonEmpty(entry["description"]) ?? "",
                instructions: nonEmpty(entry["prompt_template"]) ?? "",
                documents: documents
            )
        }
    }

    static func claudeChat(_ entry: [String: Any]) -> Chat? {
        guard let identifier = nonEmpty(entry["uuid"]) else { return nil }
        let messages = (entry["chat_messages"] as? [[String: Any]] ?? []).compactMap { message -> Message? in
            var text = nonEmpty(message["text"]) ?? ""
            if text.isEmpty {
                text = (message["content"] as? [[String: Any]] ?? [])
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { nonEmpty($0["text"]) }
                    .joined(separator: "\n")
            }
            guard !text.isEmpty else { return nil }
            return Message(isFromUser: (message["sender"] as? String) == "human", text: text)
        }
        guard !messages.isEmpty else { return nil }
        let title = nonEmpty(entry["name"]) ?? String(messages[0].text.prefix(60))
        return Chat(id: "claude-" + identifier, source: .claude, title: title,
                    date: isoDate(entry["updated_at"]) ?? isoDate(entry["created_at"]), messages: messages)
    }

    /// ChatGPT stores a tree of messages; the conversation shown is the path from `current_node` up to the root.
    static func chatGPTChat(_ entry: [String: Any]) -> Chat? {
        guard let mapping = entry["mapping"] as? [String: [String: Any]] else { return nil }
        var path: [[String: Any]] = []
        var nodeIdentifier = nonEmpty(entry["current_node"])
        if nodeIdentifier == nil {
            // No current node: follow the newest leaf.
            nodeIdentifier = mapping.filter { ($0.value["children"] as? [Any])?.isEmpty ?? true }
                .max { messageTime($0.value) < messageTime($1.value) }?.key
        }
        var visited = Set<String>()
        while let identifier = nodeIdentifier, let node = mapping[identifier], !visited.contains(identifier) {
            visited.insert(identifier)
            path.append(node)
            nodeIdentifier = nonEmpty(node["parent"])
        }
        let messages = path.reversed().compactMap { node -> Message? in
            guard let message = node["message"] as? [String: Any],
                  let role = (message["author"] as? [String: Any])?["role"] as? String,
                  role == "user" || role == "assistant" else { return nil }
            let content = message["content"] as? [String: Any]
            let parts = (content?["parts"] as? [Any] ?? []).compactMap { $0 as? String }
            let text = (parts.isEmpty ? [nonEmpty(content?["text"]) ?? ""] : parts)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Message(isFromUser: role == "user", text: text)
        }
        guard !messages.isEmpty else { return nil }
        let identifier = nonEmpty(entry["conversation_id"]) ?? nonEmpty(entry["id"]) ?? UUID().uuidString
        let timestamp = (entry["update_time"] as? Double) ?? (entry["create_time"] as? Double)
        return Chat(id: "chatgpt-" + identifier, source: .chatGPT,
                    title: nonEmpty(entry["title"]) ?? String(messages[0].text.prefix(60)),
                    date: timestamp.map { Date(timeIntervalSince1970: $0) }, messages: messages)
    }

    private static func messageTime(_ node: [String: Any]) -> Double {
        ((node["message"] as? [String: Any])?["create_time"] as? Double) ?? 0
    }

    // MARK: Searching

    public struct SearchHit: Equatable, Sendable {
        public var chat: Chat
        public var snippet: String
    }

    /// Chats that contain the words of the query (diacritics and case ignored); title matches and newer chats first.
    public static func search(_ query: String, in chats: [Chat], limit: Int = 8) -> [SearchHit] {
        let words = fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return [] }
        var scored: [(hit: SearchHit, score: Int)] = []
        for chat in chats {
            let title = fold(chat.title)
            var score = 0
            var snippet = ""
            for word in words {
                if title.contains(word) { score += 5 }
                if let message = chat.messages.first(where: { fold($0.text).contains(word) }) {
                    score += 2
                    if snippet.isEmpty { snippet = excerpt(of: message.text, around: word) }
                }
            }
            // Every word has to appear somewhere.
            let allFound = words.allSatisfy { word in title.contains(word) || chat.messages.contains { fold($0.text).contains(word) } }
            guard allFound, score > 0 else { continue }
            scored.append((SearchHit(chat: chat, snippet: snippet.isEmpty ? String(chat.messages[0].text.prefix(160)) : snippet), score))
        }
        return scored.sorted { first, second in
            if first.score != second.score { return first.score > second.score }
            return (first.hit.chat.date ?? .distantPast) > (second.hit.chat.date ?? .distantPast)
        }.prefix(limit).map(\.hit)
    }

    /// The chat or project that best matches a title; exact, then starts with, then contains.
    public static func bestTitleMatch<T>(_ title: String, in items: [T], name: (T) -> String) -> T? {
        let wanted = fold(title)
        guard !wanted.isEmpty else { return nil }
        if let exact = items.first(where: { fold(name($0)) == wanted }) { return exact }
        if let prefix = items.first(where: { fold(name($0)).hasPrefix(wanted) }) { return prefix }
        return items.first(where: { fold(name($0)).contains(wanted) })
    }

    public static func searchResultText(_ hits: [SearchHit]) -> String {
        guard !hits.isEmpty else { return "Nothing found in the imported Claude and ChatGPT chats." }
        return hits.map { hit in
            let date = hit.chat.date.map { " · " + dayFormatter.string(from: $0) } ?? ""
            return "\(hit.chat.title) (\(hit.chat.source.displayName)\(date)): …\(hit.snippet)…"
        }.joined(separator: "\n")
    }

    /// The conversation as text, cut to a size the model can read; the start and the end matter most.
    public static func transcript(_ chat: Chat, maximumCharacters: Int = 12_000) -> String {
        let lines = chat.messages.map { ($0.isFromUser ? "Eu: " : "\(chat.source.displayName): ") + $0.text }
        let full = "Chat: \(chat.title) (\(chat.source.displayName))\n\n" + lines.joined(separator: "\n\n")
        guard full.count > maximumCharacters else { return full }
        let half = maximumCharacters / 2
        return String(full.prefix(half)) + "\n\n[… mijlocul conversației a fost omis …]\n\n" + String(full.suffix(half))
    }

    public static func projectText(_ project: Project, maximumCharacters: Int = 12_000) -> String {
        var text = "Claude project: \(project.name)"
        if !project.summary.isEmpty { text += "\n\(project.summary)" }
        if !project.instructions.isEmpty { text += "\n\nInstructions:\n\(project.instructions)" }
        for document in project.documents { text += "\n\n--- \(document.name) ---\n\(document.text)" }
        return text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) + "\n[…]" : text
    }

    /// A SKILL.md made from a Claude project, so Macky can follow it like any other skill.
    public static func skillMarkdown(for project: Project) -> String {
        let description = (project.summary.isEmpty ? "Instrucțiunile proiectului Claude „\(project.name)”." : project.summary)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        var markdown = "---\nname: \(project.name.replacingOccurrences(of: "\n", with: " "))\ndescription: \"\(description)\"\n---\n\n"
        markdown += project.instructions.isEmpty ? "Lucrează în contextul proiectului „\(project.name)”.\n" : project.instructions + "\n"
        for document in project.documents {
            markdown += "\n## \(document.name)\n\n\(document.text)\n"
        }
        return markdown
    }

    // MARK: Helpers

    static func excerpt(of text: String, around word: String) -> String {
        let folded = fold(text)
        guard let range = folded.range(of: word) else { return String(text.prefix(160)) }
        let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
        let characters = Array(text)
        let start = min(max(0, offset - 70), characters.count)
        let end = max(start, min(characters.count, offset + word.count + 90))
        return String(characters[start..<end]).replacingOccurrences(of: "\n", with: " ")
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ro_RO")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}
