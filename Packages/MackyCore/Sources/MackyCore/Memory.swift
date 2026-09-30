import Foundation

// MARK: - Memory items

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case profile      // about the user: role, business, habits
    case person       // clients, colleagues, family, contacts
    case project      // ongoing work and its status
    case preference   // how the user likes things done
    case location     // where things are: folders, links, files, accounts
    case lesson       // learned from mistakes and corrections
    case fact         // anything else worth keeping

    public var displayName: String {
        switch self {
        case .profile: return "Despre tine"
        case .person: return "Oameni și clienți"
        case .project: return "Proiecte"
        case .preference: return "Preferințe"
        case .location: return "Unde găsesc lucruri"
        case .lesson: return "Lecții învățate"
        case .fact: return "Diverse"
        }
    }
}

public enum MemorySource: String, Codable, Sendable {
    case user       // the user said "ține minte…" or typed it in
    case learned    // extracted automatically from conversations
    case imported
}

public struct MemoryItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: MemoryKind
    /// Short title, usually the entity: "Raluca Dicu", "Facturi", "Stil mailuri".
    public var subject: String
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    public var source: MemorySource
    /// Pinned memories are always given to the model.
    public var isPinned: Bool

    public init(id: UUID = UUID(), kind: MemoryKind, subject: String, content: String, source: MemorySource,
                isPinned: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.lastUsedAt = nil
        self.useCount = 0
        self.source = source
        self.isPinned = isPinned
    }

    public var searchableText: String { subject + " " + content }

    /// One line as the model sees it.
    public var promptLine: String {
        "- [\(kind.rawValue)] \(subject): \(content)"
    }
}

// MARK: - Text normalization shared by memory, procedures and history

public enum MemoryText {
    /// Words too common to say anything about relevance (Romanian and English).
    static let stopwords: Set<String> = [
        "si", "sau", "de", "la", "in", "din", "pe", "cu", "ca", "sa", "se", "nu", "da", "un", "o", "unei", "unui", "este", "e", "sunt",
        "am", "ai", "are", "au", "ce", "cum", "care", "cine", "unde", "cand", "mai", "mi", "ma", "te", "ti", "il", "le", "lui", "lor",
        "al", "ale", "ai", "asta", "acest", "aceasta", "acum", "doar", "foarte", "tot", "toate", "pentru", "catre", "fara", "despre",
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "at", "for", "with", "is", "are", "be", "it", "this", "that", "my", "me",
        "i", "you", "please", "te rog", "rog", "hai", "macky"
    ]

    /// Lowercased, without diacritics, split into words, stopwords removed, and cut to 6 letters —
    /// a crude but language-agnostic stemmer: "clientul", "clientului", "clienti" all become "client".
    public static func keywords(of text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            // Single digits stay: "volumul la 5" and "volumul la 6" are different requests.
            .filter { ($0.count >= 2 || (!$0.isEmpty && $0.allSatisfy(\.isNumber))) && !stopwords.contains($0) }
            .map { $0.count > 6 ? String($0.prefix(6)) : $0 }
    }

    public static func cosineSimilarity(_ first: [Float], _ second: [Float]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var dotProduct: Float = 0
        var firstNorm: Float = 0
        var secondNorm: Float = 0
        for index in first.indices {
            dotProduct += first[index] * second[index]
            firstNorm += first[index] * first[index]
            secondNorm += second[index] * second[index]
        }
        guard firstNorm > 0, secondNorm > 0 else { return 0 }
        return Double(dotProduct / (firstNorm.squareRoot() * secondNorm.squareRoot()))
    }
}

// MARK: - Retrieval

/// Finds the memories relevant to a request: keyword relevance (BM25) combined with meaning
/// (sentence vectors, when available), nudged by how often and how recently a memory helped.
public enum MemoryRetriever {
    public struct Match: Equatable {
        public var item: MemoryItem
        public var score: Double
    }

    public static let minimumScore = 0.18

    public static func rank(
        query: String,
        items: [MemoryItem],
        queryVector: [Float]? = nil,
        vectorsByIdentifier: [UUID: [Float]] = [:],
        limit: Int = 8,
        now: Date = Date()
    ) -> [Match] {
        let queryKeywords = Set(MemoryText.keywords(of: query))
        guard !items.isEmpty, !queryKeywords.isEmpty || queryVector != nil else { return [] }

        // BM25 over subject + content.
        let documents = items.map { MemoryText.keywords(of: $0.searchableText) }
        let averageLength = max(1, Double(documents.map(\.count).reduce(0, +)) / Double(documents.count))
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for keyword in Set(document) { documentFrequency[keyword, default: 0] += 1 }
        }
        let documentCount = Double(documents.count)
        let keywordScores: [Double] = documents.map { document in
            var score = 0.0
            let length = Double(document.count)
            for keyword in queryKeywords {
                let termFrequency = Double(document.filter { $0 == keyword }.count)
                guard termFrequency > 0 else { continue }
                let frequency = Double(documentFrequency[keyword] ?? 0)
                let inverseDocumentFrequency = log(1 + (documentCount - frequency + 0.5) / (frequency + 0.5))
                score += inverseDocumentFrequency * (termFrequency * 2.2) / (termFrequency + 1.2 * (0.25 + 0.75 * length / averageLength))
            }
            return score
        }
        let maximumKeywordScore = keywordScores.max() ?? 0

        var matches: [Match] = []
        for (index, item) in items.enumerated() {
            let keywordRelevance = maximumKeywordScore > 0 ? keywordScores[index] / maximumKeywordScore : 0
            var meaningRelevance = 0.0
            if let queryVector, let itemVector = vectorsByIdentifier[item.id] {
                // Sentence vectors of unrelated texts still score ~0.3–0.5; rescale so only real closeness counts.
                meaningRelevance = max(0, (MemoryText.cosineSimilarity(queryVector, itemVector) - 0.55) / 0.45)
            }
            var score = queryVector == nil ? keywordRelevance : 0.55 * keywordRelevance + 0.45 * meaningRelevance
            // A strong keyword hit (e.g. a client's name) counts even if vectors disagree.
            if keywordScores[index] > 0 { score = max(score, 0.2 + 0.5 * keywordRelevance) }
            guard score > 0 else { continue }
            // Memories that helped often and recently are slightly preferred.
            score += min(0.1, Double(item.useCount) * 0.01)
            if let lastUsedAt = item.lastUsedAt, now.timeIntervalSince(lastUsedAt) < 7 * 24 * 3600 { score += 0.03 }
            if item.kind == .lesson { score += 0.05 }
            if score >= minimumScore {
                matches.append(Match(item: item, score: score))
            }
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }
}

// MARK: - Prompt block

public enum MemoryContextBuilder {
    /// The memory block added to each request. Kept within a character budget so memory never
    /// becomes the expensive part of a request.
    public static func contextBlock(
        profileSummary: String?,
        pinnedItems: [MemoryItem],
        relevantItems: [MemoryItem],
        characterBudget: Int = 2400
    ) -> String? {
        var lines: [String] = []
        var usedCharacters = 0
        var includedIdentifiers = Set<UUID>()

        if let profileSummary = profileSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !profileSummary.isEmpty {
            let summary = String(profileSummary.prefix(900))
            lines.append("About the user: " + summary)
            usedCharacters += summary.count
        }
        for item in pinnedItems + relevantItems where !includedIdentifiers.contains(item.id) {
            let line = item.promptLine
            guard usedCharacters + line.count <= characterBudget else { break }
            lines.append(line)
            usedCharacters += line.count
            includedIdentifiers.insert(item.id)
        }
        guard !lines.isEmpty else { return nil }
        return "What you remember (Macky's memory; use it naturally, do not recite it unless asked, and follow the lessons):\n"
            + lines.joined(separator: "\n")
    }
}

// MARK: - Learning (the curator)

/// One finished exchange, as the curator sees it.
public struct CuratorExchange: Codable, Equatable, Sendable {
    public var date: Date
    public var question: String
    public var answer: String
    public var actions: [String]
    public var failures: [String]

    public init(date: Date = Date(), question: String, answer: String, actions: [String], failures: [String]) {
        self.date = date
        self.question = question
        self.answer = answer
        self.actions = actions
        self.failures = failures
    }
}

public enum MemoryOperation: Equatable, Sendable {
    case add(kind: MemoryKind, subject: String, content: String)
    case update(identifier: UUID, subject: String?, content: String)
    case delete(identifier: UUID)
}

/// Turns conversations into memories. A cheap model reads recent exchanges plus the memories
/// that may already cover them, and answers with add/update/delete operations — so knowledge is
/// merged and corrected instead of piling up duplicates.
public enum MemoryCurator {
    /// Phrases that mean "this is worth remembering now" or "you got it wrong".
    static let rememberCues = [
        "tine minte", "retine", "nu uita", "memoreaza", "de acum", "de acum inainte", "mereu", "intotdeauna", "niciodata",
        "prefer", "imi place", "nu-mi place", "clientul", "clienta", "clientii", "se afla", "gasesti", "e in folderul", "in drive",
        "numarul lui", "numarul ei", "mailul lui", "mailul ei", "remember", "from now on", "always", "never", "my client"
    ]
    static let correctionCues = [
        "nu asta", "nu, ", "gresit", "nu e bine", "nu e corect", "am zis", "ti-am zis", "nu am cerut", "nu voiam", "altceva",
        "din nou", "iar ai", "that's wrong", "not that", "wrong", "i said"
    ]

    public static func isCorrection(_ text: String) -> Bool {
        let folded = " " + text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) + " "
        return correctionCues.contains { folded.contains($0) }
    }

    /// Curating costs a (cheap) model call, so it runs right away only when there is a clear signal;
    /// otherwise exchanges are batched and curated together later.
    public static func shouldCurateImmediately(question: String, hadFailure: Bool) -> Bool {
        if hadFailure || isCorrection(question) { return true }
        let folded = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return rememberCues.contains { folded.contains($0) }
    }

    public static let batchSize = 6

    public static func messages(exchanges: [CuratorExchange], existingMemories: [MemoryItem]) -> [ChatMessage] {
        let system = """
        You maintain the long-term memory of Macky, a personal assistant on the user's Mac. From the conversation excerpts, \
        decide what is worth remembering for the future, and keep the memory clean.

        Keep only durable, useful knowledge:
        - people and clients: who they are, company, role, how the user works with them, contact details the user mentions, project status;
        - where things are: Google Drive folders, links, file paths, accounts, which app is used for what;
        - the user's preferences and style (tone of emails, formats, tools they like);
        - lessons: when an action failed or the user corrected Macky, write what to do next time
          (form: "Când utilizatorul cere X, fă Y, nu Z."), with the concrete detail that fixes it;
        - facts about the user's work and life that will matter again.
        Never keep: small talk, one-off questions, weather, prices that change, passwords or card numbers, anything already known.

        Rules:
        - One idea per memory. Content under 280 characters, written in Romanian, self-contained (name the person or thing).
        - If an existing memory covers the same thing, UPDATE it (merge the new detail) instead of adding a duplicate.
        - If something the user says contradicts a memory, UPDATE or DELETE that memory.
        - Most exchanges contain nothing worth keeping: then answer [].

        Answer ONLY with a JSON array, no other text. Items:
        {"op":"add","kind":"profile|person|project|preference|location|lesson|fact","subject":"...","content":"..."}
        {"op":"update","id":"<existing id>","subject":"...","content":"<full new content>"}
        {"op":"delete","id":"<existing id>"}
        """
        var userLines: [String] = []
        if !existingMemories.isEmpty {
            userLines.append("Existing memories that may be related:")
            for memory in existingMemories {
                userLines.append("id=\(memory.id.uuidString) [\(memory.kind.rawValue)] \(memory.subject): \(memory.content)")
            }
            userLines.append("")
        }
        userLines.append("Recent exchanges:")
        for exchange in exchanges {
            userLines.append("User: \(exchange.question)")
            if !exchange.actions.isEmpty { userLines.append("Macky did: \(exchange.actions.joined(separator: "; "))") }
            if !exchange.failures.isEmpty { userLines.append("Failed: \(exchange.failures.joined(separator: "; "))") }
            userLines.append("Macky answered: \(String(exchange.answer.prefix(600)))")
            userLines.append("")
        }
        return [ChatMessage(role: .system, text: system), ChatMessage(role: .user, text: userLines.joined(separator: "\n"))]
    }

    /// Reads the curator's answer, tolerating code fences and stray text around the JSON.
    public static func parseOperations(from responseText: String, knownIdentifiers: Set<UUID>) -> [MemoryOperation] {
        guard let entries = jsonArray(in: responseText) else { return [] }
        return entries.compactMap { entry in
            switch (entry["op"] as? String)?.lowercased() {
            case "add":
                guard let kind = MemoryKind(rawValue: ((entry["kind"] as? String) ?? "fact").lowercased()),
                      let content = cleaned(entry["content"]) else { return nil }
                return .add(kind: kind, subject: cleaned(entry["subject"]) ?? String(content.prefix(40)), content: String(content.prefix(500)))
            case "update":
                guard let identifier = (entry["id"] as? String).flatMap(UUID.init(uuidString:)), knownIdentifiers.contains(identifier),
                      let content = cleaned(entry["content"]) else { return nil }
                return .update(identifier: identifier, subject: cleaned(entry["subject"]), content: String(content.prefix(500)))
            case "delete":
                guard let identifier = (entry["id"] as? String).flatMap(UUID.init(uuidString:)), knownIdentifiers.contains(identifier) else { return nil }
                return .delete(identifier: identifier)
            default:
                return nil
            }
        }
    }

    // MARK: Consolidation ("sleep")

    /// Once a day, all memories are reviewed together: duplicates merged, stale ones removed, and a short
    /// profile written. The profile is what every request carries, so it is kept small.
    public static func consolidationMessages(memories: [MemoryItem], currentProfileSummary: String?) -> [ChatMessage] {
        let system = """
        You consolidate the long-term memory of Macky, a personal assistant. Review all memories:
        - merge duplicates and near-duplicates (update one, delete the others);
        - delete memories that are outdated, trivial or contradicted by newer ones;
        - write "profile_summary": at most 700 characters in Romanian with the most important things about the user
          (who they are, their work, main clients and tools, strongest preferences). It is sent with every request, so keep it dense.
        Answer ONLY with JSON: {"profile_summary":"...","operations":[ ...same operation format... ]}
        Operation formats: {"op":"update","id":"...","subject":"...","content":"..."}, {"op":"delete","id":"..."}.
        """
        var lines = ["Current profile: \(currentProfileSummary ?? "(none)")", "", "Memories:"]
        for memory in memories {
            lines.append("id=\(memory.id.uuidString) [\(memory.kind.rawValue)] \(memory.subject): \(memory.content) (used \(memory.useCount)x)")
        }
        return [ChatMessage(role: .system, text: system), ChatMessage(role: .user, text: lines.joined(separator: "\n"))]
    }

    public static func parseConsolidation(from responseText: String, knownIdentifiers: Set<UUID>) -> (profileSummary: String?, operations: [MemoryOperation]) {
        guard let object = jsonObject(in: responseText) else { return (nil, []) }
        let profileSummary = cleaned(object["profile_summary"])
        var operations: [MemoryOperation] = []
        if let entries = object["operations"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: entries),
           let text = String(data: data, encoding: .utf8) {
            operations = parseOperations(from: text, knownIdentifiers: knownIdentifiers).filter {
                if case .add = $0 { return false }
                return true
            }
        }
        return (profileSummary.map { String($0.prefix(900)) }, operations)
    }

    // MARK: JSON helpers

    static func cleaned(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func jsonArray(in text: String) -> [[String: Any]]? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return array
    }

    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}
