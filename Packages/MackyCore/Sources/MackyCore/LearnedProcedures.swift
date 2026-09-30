import Foundation

/// A tool call saved so it can be replayed later without asking the model.
public struct StoredToolCall: Codable, Equatable, Sendable {
    public var name: String
    public var argumentsJSON: String

    public init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = Self.canonicalJSON(argumentsJSON)
    }

    public init(_ toolCall: ChatToolCall) {
        self.init(name: toolCall.name, argumentsJSON: toolCall.argumentsJSON)
    }

    public func chatToolCall(identifier: String) -> ChatToolCall {
        ChatToolCall(identifier: identifier, name: name, argumentsJSON: argumentsJSON)
    }

    /// Same arguments written in a different key order or spacing count as the same call.
    static func canonicalJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let canonicalText = String(data: canonicalData, encoding: .utf8) else { return text }
        return canonicalText
    }
}

/// A request Macky has learned to handle by itself: the model solved it the same way twice,
/// so the next time the same tool calls run directly — no screenshot, no model, no tokens.
public struct LearnedProcedure: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The request's keywords, sorted; what new requests are compared with.
    public var requestKey: [String]
    public var exampleRequest: String
    public var toolCalls: [StoredToolCall]
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    public var failureCount: Int
    public var isEnabled: Bool

    public init(id: UUID = UUID(), requestKey: [String], exampleRequest: String, toolCalls: [StoredToolCall], createdAt: Date = Date()) {
        self.id = id
        self.requestKey = requestKey
        self.exampleRequest = exampleRequest
        self.toolCalls = toolCalls
        self.createdAt = createdAt
        self.lastUsedAt = nil
        self.useCount = 0
        self.failureCount = 0
        self.isEnabled = true
    }
}

/// A request seen solved once; promoted to a procedure after enough identical successful runs.
public struct ProcedureCandidate: Codable, Equatable, Sendable {
    public var requestKey: [String]
    public var exampleRequest: String
    public var toolCalls: [StoredToolCall]
    public var successCount: Int
    public var lastSeenAt: Date
}

/// Everything learned about solving repeated requests, saved as one file.
public struct ProcedureBook: Codable, Equatable, Sendable {
    public var procedures: [LearnedProcedure] = []
    public var candidates: [ProcedureCandidate] = []

    public init() {}

    /// Identical successful runs needed before Macky trusts itself to repeat a request alone.
    public static let runsNeededForPromotion = 2
    /// A procedure that failed this many times is switched off and the model takes over again.
    public static let failuresBeforeDisabling = 2
    public static let minimumSimilarity = 0.85
    static let maximumCandidates = 200

    /// Tools whose effect depends only on their arguments, not on what is on screen or the current date.
    public static let cacheableTools: Set<String> = [
        MackyTool.spotify, .systemControl, .openApplication, .openURL, .arrangeWindow, .clickElement, .pressKeys, .runAppleScript
    ].reduce(into: Set<String>()) { $0.insert($1.rawValue) }

    /// Words that point at the screen or at an earlier message: the same words can mean different things each time.
    static let contextWords: Set<String> = [
        "asta", "aceasta", "acesta", "aici", "acolo", "ala", "aia", "aceea", "acela", "el", "ea", "iar",
        "this", "that", "here", "there", "it", "again", "ecran", "ecranul", "selectat", "selectia"
    ]

    public static func requestKey(for request: String) -> [String] {
        Array(Set(MemoryText.keywords(of: request))).sorted()
    }

    /// Whether a solved request may become a procedure.
    public static func isCacheable(request: String, toolCalls: [ChatToolCall]) -> Bool {
        let meaningfulCalls = toolCalls.filter { $0.name != MackyTool.taskDone.rawValue }
        guard !meaningfulCalls.isEmpty, meaningfulCalls.count <= 6,
              meaningfulCalls.allSatisfy({ cacheableTools.contains($0.name) }) else { return false }
        let folded = request.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = Set(folded.components(separatedBy: CharacterSet.alphanumerics.inverted))
        guard words.isDisjoint(with: contextWords), !MemoryCurator.isCorrection(request) else { return false }
        return requestKey(for: request).count >= 1
    }

    static func similarity(_ first: [String], _ second: [String]) -> Double {
        let firstSet = Set(first)
        let secondSet = Set(second)
        guard !firstSet.isEmpty || !secondSet.isEmpty else { return 0 }
        return Double(firstSet.intersection(secondSet).count) / Double(firstSet.union(secondSet).count)
    }

    /// The enabled procedure that answers this request, if any.
    public func match(_ request: String) -> LearnedProcedure? {
        let key = Self.requestKey(for: request)
        guard !key.isEmpty else { return nil }
        return procedures
            .filter(\.isEnabled)
            .map { ($0, Self.similarity(key, $0.requestKey)) }
            .filter { $0.1 >= Self.minimumSimilarity }
            .max { $0.1 < $1.1 }?.0
    }

    /// Records a request the model solved successfully. Returns the procedure when this run promoted it.
    @discardableResult
    public mutating func recordSuccessfulRun(request: String, toolCalls: [ChatToolCall], now: Date = Date()) -> LearnedProcedure? {
        guard Self.isCacheable(request: request, toolCalls: toolCalls) else { return nil }
        let key = Self.requestKey(for: request)
        let storedCalls = toolCalls.filter { $0.name != MackyTool.taskDone.rawValue }.map(StoredToolCall.init)
        // Already a procedure (e.g. a disabled one the model now solves the same way again): nothing new to learn.
        if procedures.contains(where: { $0.requestKey == key && $0.toolCalls == storedCalls && $0.isEnabled }) { return nil }

        if let index = candidates.firstIndex(where: { $0.requestKey == key }) {
            if candidates[index].toolCalls == storedCalls {
                candidates[index].successCount += 1
            } else {
                // Solved differently this time: start counting again with the newer way.
                candidates[index].toolCalls = storedCalls
                candidates[index].successCount = 1
            }
            candidates[index].lastSeenAt = now
            candidates[index].exampleRequest = request
            guard candidates[index].successCount >= Self.runsNeededForPromotion else { return nil }
            let candidate = candidates.remove(at: index)
            procedures.removeAll { $0.requestKey == key }
            let procedure = LearnedProcedure(requestKey: key, exampleRequest: candidate.exampleRequest, toolCalls: candidate.toolCalls, createdAt: now)
            procedures.append(procedure)
            return procedure
        }

        candidates.append(ProcedureCandidate(requestKey: key, exampleRequest: request, toolCalls: storedCalls, successCount: 1, lastSeenAt: now))
        if candidates.count > Self.maximumCandidates {
            candidates.sort { $0.lastSeenAt > $1.lastSeenAt }
            candidates.removeLast(candidates.count - Self.maximumCandidates)
        }
        return nil
    }

    public mutating func recordUse(of identifier: UUID, now: Date = Date()) {
        guard let index = procedures.firstIndex(where: { $0.id == identifier }) else { return }
        procedures[index].useCount += 1
        procedures[index].lastUsedAt = now
    }

    /// A replay failed or the user corrected it right after. Returns true when the procedure got switched off.
    @discardableResult
    public mutating func recordFailure(of identifier: UUID) -> Bool {
        guard let index = procedures.firstIndex(where: { $0.id == identifier }) else { return false }
        procedures[index].failureCount += 1
        if procedures[index].failureCount >= Self.failuresBeforeDisabling {
            procedures[index].isEnabled = false
            return true
        }
        return false
    }

    public mutating func setEnabled(_ isEnabled: Bool, for identifier: UUID) {
        guard let index = procedures.firstIndex(where: { $0.id == identifier }) else { return }
        procedures[index].isEnabled = isEnabled
        if isEnabled { procedures[index].failureCount = 0 }
    }

    public mutating func remove(_ identifier: UUID) {
        procedures.removeAll { $0.id == identifier }
    }
}

// MARK: - History

/// One request and what Macky did about it, kept for the History window.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Route: String, Codable, Sendable {
        case model          // answered by the AI model
        case quickCommand   // handled locally by a matcher
        case procedure      // replayed a learned procedure
        case backgroundAgent
        case routine
        case meeting
    }

    public var id: UUID
    public var date: Date
    public var question: String
    public var answer: String
    public var actions: [String]
    public var route: Route
    public var modelIdentifier: String?
    public var costInDollars: Double?
    public var durationInSeconds: Double?

    public init(id: UUID = UUID(), date: Date = Date(), question: String, answer: String, actions: [String] = [], route: Route,
                modelIdentifier: String? = nil, costInDollars: Double? = nil, durationInSeconds: Double? = nil) {
        self.id = id
        self.date = date
        self.question = question
        self.answer = answer
        self.actions = actions
        self.route = route
        self.modelIdentifier = modelIdentifier
        self.costInDollars = costInDollars
        self.durationInSeconds = durationInSeconds
    }
}

public enum HistorySearch {
    /// Newest first; with a query, only entries containing every query word (diacritics and case ignored).
    public static func filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
        let queryWords = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let sortedEntries = entries.sorted { $0.date > $1.date }
        guard !queryWords.isEmpty else { return sortedEntries }
        return sortedEntries.filter { entry in
            let haystack = (entry.question + " " + entry.answer + " " + entry.actions.joined(separator: " "))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return queryWords.allSatisfy { haystack.contains($0) }
        }
    }
}
