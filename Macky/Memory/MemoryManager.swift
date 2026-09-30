import Foundation
import MackyCore

/// Macky's long-term memory. It
/// - gives the model the few memories relevant to each request (plus a short profile), within a small budget;
/// - learns by itself: a cheap model reads finished conversations and adds, merges or corrects memories,
///   right away after corrections, failures or "ține minte", otherwise in batches;
/// - writes lessons from mistakes, which are always preferred when relevant;
/// - once a day "sleeps" on it: merges duplicates, drops stale memories, rewrites the profile;
/// - learns procedures: requests solved the same way twice are replayed directly afterwards, without tokens.
/// Everything is stored as JSON in ~/Library/Application Support/Macky and editable in the Memory window.
@MainActor
final class MemoryManager: ObservableObject {
    @Published private(set) var items: [MemoryItem] = []
    @Published private(set) var profileSummary: String?
    @Published private(set) var procedureBook = ProcedureBook()
    @Published private(set) var lastConsolidationDate: Date?
    @Published private(set) var isLearning = false
    /// Whether meaning-based search is available (Apple's on-device model loaded).
    @Published private(set) var usesMeaningSearch = false
    /// How many requests were answered by learned procedures instead of the model.
    @Published private(set) var requestsAnsweredWithoutModel = 0

    private let settings: AppSettings
    private let apiKeyStore: OpenRouterAPIKeyStore
    private let openRouterClient: OpenRouterClient
    private let embeddingService = EmbeddingService()
    /// Meaning vectors by memory, with the text they were computed from (recomputed when the text changes).
    private var vectors: [UUID: (text: String, vector: [Float])] = [:]
    private var pendingExchanges: [CuratorExchange] = []
    private var previousExchange: CuratorExchange?

    private let memoryFileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("memory.json")
    private let proceduresFileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("procedures.json")

    private struct MemoryFile: Codable {
        var items: [MemoryItem]
        var profileSummary: String?
        var lastConsolidationDate: Date?
        var pendingExchanges: [CuratorExchange]
        var requestsAnsweredWithoutModel: Int?
    }

    init(settings: AppSettings, apiKeyStore: OpenRouterAPIKeyStore, openRouterClient: OpenRouterClient) {
        self.settings = settings
        self.apiKeyStore = apiKeyStore
        self.openRouterClient = openRouterClient
        load()
    }

    func start() {
        Task {
            usesMeaningSearch = await embeddingService.prepare()
            await refreshVectors()
            await consolidateIfDue()
        }
    }

    // MARK: Retrieval

    /// The memory block for one request, or nil when there is nothing relevant.
    func contextBlock(for question: String) async -> String? {
        guard settings.memoryEnabled, !items.isEmpty || profileSummary != nil else { return nil }
        let relevantItems = await relevantMemories(for: question, limit: 8)
        let pinnedItems = items.filter(\.isPinned)
        markUsed(relevantItems.map(\.id))
        return MemoryContextBuilder.contextBlock(profileSummary: profileSummary, pinnedItems: pinnedItems, relevantItems: relevantItems)
    }

    private func relevantMemories(for text: String, limit: Int) async -> [MemoryItem] {
        let queryVector = usesMeaningSearch ? await embeddingService.vector(for: text) : nil
        let vectorsByIdentifier = vectors.mapValues(\.vector)
        return MemoryRetriever.rank(query: text, items: items, queryVector: queryVector, vectorsByIdentifier: vectorsByIdentifier, limit: limit)
            .map(\.item)
    }

    private func markUsed(_ identifiers: [UUID]) {
        guard !identifiers.isEmpty else { return }
        let now = Date()
        for index in items.indices where identifiers.contains(items[index].id) {
            items[index].useCount += 1
            items[index].lastUsedAt = now
        }
        saveMemory()
    }

    private func refreshVectors() async {
        guard usesMeaningSearch else { return }
        for item in items where vectors[item.id]?.text != item.searchableText {
            let text = item.searchableText
            if let vector = await embeddingService.vector(for: text) {
                vectors[item.id] = (text, vector)
            }
        }
        let existingIdentifiers = Set(items.map(\.id))
        vectors = vectors.filter { existingIdentifiers.contains($0.key) }
    }

    // MARK: Memory tools (called by the model)

    func remember(kind: MemoryKind, subject: String, content: String) async -> String {
        // Same subject and kind: update instead of duplicating.
        if let index = items.firstIndex(where: { $0.kind == kind && MemoryText.keywords(of: $0.subject) == MemoryText.keywords(of: subject) }) {
            items[index].content = content
            items[index].updatedAt = Date()
            items[index].source = .user
        } else {
            items.append(MemoryItem(kind: kind, subject: subject, content: content, source: .user))
        }
        saveMemory()
        await refreshVectors()
        return "Saved to memory."
    }

    func forget(query: String) async -> String {
        let matches = MemoryRetriever.rank(query: query, items: items, limit: 3).filter { $0.score >= 0.45 }
        guard !matches.isEmpty else { return "No memory matches that." }
        let removedIdentifiers = Set(matches.map(\.item.id))
        items.removeAll { removedIdentifiers.contains($0.id) }
        saveMemory()
        return "Deleted: " + matches.map { "\($0.item.subject): \($0.item.content)" }.joined(separator: " | ")
    }

    func recall(query: String) async -> String {
        let found = await relevantMemories(for: query, limit: 6)
        guard !found.isEmpty else { return "Nothing in memory about that." }
        markUsed(found.map(\.id))
        return found.map(\.promptLine).joined(separator: "\n")
    }

    // MARK: Learning from conversations

    /// Called after every answered request. Cheap: curating only happens when there is something to learn.
    func recordExchange(question: String, answer: String, actions: [String], failures: [String]) {
        guard settings.memoryEnabled else { return }
        let exchange = CuratorExchange(question: question, answer: answer, actions: actions, failures: failures)
        var batch = pendingExchanges
        // A correction only makes sense together with what it corrects.
        if MemoryCurator.isCorrection(question), let previousExchange, batch.last != previousExchange {
            batch.append(previousExchange)
        }
        batch.append(exchange)
        pendingExchanges = batch
        previousExchange = exchange
        saveMemory()
        if MemoryCurator.shouldCurateImmediately(question: question, hadFailure: !failures.isEmpty)
            || pendingExchanges.count >= MemoryCurator.batchSize {
            Task { await curatePendingExchanges() }
        }
    }

    func curatePendingExchanges() async {
        guard !isLearning, !pendingExchanges.isEmpty, let apiKey = apiKeyStore.apiKey(), !apiKey.isEmpty,
              let modelIdentifier = learningModelIdentifier else { return }
        isLearning = true
        defer { isLearning = false }
        let batch = pendingExchanges
        let batchText = batch.map { $0.question + " " + $0.answer }.joined(separator: " ")
        let relatedMemories = await relevantMemories(for: batchText, limit: 12)

        do {
            let responseText = try await collectText(
                messages: MemoryCurator.messages(exchanges: batch, existingMemories: relatedMemories),
                modelIdentifier: modelIdentifier, apiKey: apiKey, maximumResponseTokens: 700
            )
            let operations = MemoryCurator.parseOperations(from: responseText, knownIdentifiers: Set(items.map(\.id)))
            apply(operations, source: .learned)
            pendingExchanges.removeAll { batch.contains($0) }
            saveMemory()
            await refreshVectors()
        } catch {
            // Kept for the next attempt; learning is never urgent.
        }
        await consolidateIfDue()
    }

    /// Once a day, with enough memories: merge, clean up and rewrite the profile.
    func consolidateIfDue(force: Bool = false) async {
        guard settings.memoryEnabled, !isLearning else { return }
        let isDue = lastConsolidationDate.map { Date().timeIntervalSince($0) > 20 * 3600 } ?? true
        guard force || (isDue && items.count >= 6) else { return }
        guard let apiKey = apiKeyStore.apiKey(), !apiKey.isEmpty, let modelIdentifier = learningModelIdentifier else { return }
        isLearning = true
        defer { isLearning = false }
        do {
            let responseText = try await collectText(
                messages: MemoryCurator.consolidationMessages(memories: items, currentProfileSummary: profileSummary),
                modelIdentifier: modelIdentifier, apiKey: apiKey, maximumResponseTokens: 2500
            )
            let result = MemoryCurator.parseConsolidation(from: responseText, knownIdentifiers: Set(items.map(\.id)))
            if let summary = result.profileSummary { profileSummary = summary }
            // Memories the user wrote or pinned are never removed automatically.
            let protectedIdentifiers = Set(items.filter { $0.isPinned || $0.source == .user }.map(\.id))
            apply(result.operations.filter {
                if case .delete(let identifier) = $0 { return !protectedIdentifiers.contains(identifier) }
                return true
            }, source: .learned)
            lastConsolidationDate = Date()
            saveMemory()
            await refreshVectors()
        } catch {
            // Tried again later.
        }
    }

    private func apply(_ operations: [MemoryOperation], source: MemorySource) {
        for operation in operations {
            switch operation {
            case .add(let kind, let subject, let content):
                items.append(MemoryItem(kind: kind, subject: subject, content: content, source: source))
            case .update(let identifier, let subject, let content):
                guard let index = items.firstIndex(where: { $0.id == identifier }) else { continue }
                if let subject { items[index].subject = subject }
                items[index].content = content
                items[index].updatedAt = Date()
            case .delete(let identifier):
                items.removeAll { $0.id == identifier }
            }
        }
    }

    /// Learning uses the fast (cheap) model.
    private var learningModelIdentifier: String? {
        let identifier = settings.fastModelIdentifier.isEmpty ? settings.powerfulModelIdentifier : settings.fastModelIdentifier
        return identifier.isEmpty ? nil : identifier
    }

    private func collectText(messages: [ChatMessage], modelIdentifier: String, apiKey: String, maximumResponseTokens: Int) async throws -> String {
        let body = try OpenRouterRequestBuilder.makeChatCompletionBody(
            modelIdentifier: modelIdentifier, messages: messages, tools: [], coordinateConvention: .imagePixels,
            disableReasoning: settings.shouldDisableReasoning(forModelIdentifier: modelIdentifier),
            maximumResponseTokens: maximumResponseTokens
        )
        do {
            return try await openRouterClient.collectChatCompletion(requestBody: body, apiKey: apiKey, purpose: .memory).text
        } catch let apiError as OpenRouterAPIError where apiError.httpStatusCode == 400 {
            // Some providers reject the reasoning switch; try once without it.
            let plainBody = try OpenRouterRequestBuilder.makeChatCompletionBody(
                modelIdentifier: modelIdentifier, messages: messages, tools: [], coordinateConvention: .imagePixels,
                maximumResponseTokens: maximumResponseTokens
            )
            return try await openRouterClient.collectChatCompletion(requestBody: plainBody, apiKey: apiKey, purpose: .memory).text
        }
    }

    // MARK: Learned procedures

    func procedure(matching request: String) -> LearnedProcedure? {
        guard settings.learnedProceduresEnabled else { return nil }
        return procedureBook.match(request)
    }

    /// Returns the procedure when this run taught Macky a new one.
    @discardableResult
    func recordSuccessfulRun(request: String, toolCalls: [ChatToolCall]) -> LearnedProcedure? {
        guard settings.learnedProceduresEnabled else { return nil }
        let promotedProcedure = procedureBook.recordSuccessfulRun(request: request, toolCalls: toolCalls)
        saveProcedures()
        return promotedProcedure
    }

    func recordProcedureUse(_ identifier: UUID) {
        procedureBook.recordUse(of: identifier)
        requestsAnsweredWithoutModel += 1
        saveProcedures()
        saveMemory()
    }

    func recordProcedureFailure(_ identifier: UUID) {
        procedureBook.recordFailure(of: identifier)
        saveProcedures()
    }

    // MARK: Editing (Memory window)

    /// Claude's own memory from its data export: kept as one editable item, replaced on each import.
    func importClaudeMemory(_ text: String) {
        let content = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !content.isEmpty else { return }
        let subject = "Din memoria Claude"
        if var existing = items.first(where: { $0.subject == subject }) {
            existing.content = content
            update(existing)
        } else {
            add(kind: .profile, subject: subject, content: content, isPinned: false)
        }
    }

    func add(kind: MemoryKind, subject: String, content: String, isPinned: Bool) {
        items.append(MemoryItem(kind: kind, subject: subject, content: content, source: .user, isPinned: isPinned))
        saveMemory()
        Task { await refreshVectors() }
    }

    func update(_ item: MemoryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updatedItem = item
        updatedItem.updatedAt = Date()
        items[index] = updatedItem
        saveMemory()
        Task { await refreshVectors() }
    }

    func delete(_ identifier: UUID) {
        items.removeAll { $0.id == identifier }
        saveMemory()
    }

    func setProfileSummary(_ summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        profileSummary = trimmed.isEmpty ? nil : trimmed
        saveMemory()
    }

    func deleteEverything() {
        items = []
        profileSummary = nil
        pendingExchanges = []
        previousExchange = nil
        vectors = [:]
        procedureBook = ProcedureBook()
        saveMemory()
        saveProcedures()
    }

    func setProcedureEnabled(_ isEnabled: Bool, identifier: UUID) {
        procedureBook.setEnabled(isEnabled, for: identifier)
        saveProcedures()
    }

    func deleteProcedure(_ identifier: UUID) {
        procedureBook.remove(identifier)
        saveProcedures()
    }

    var pendingExchangeCount: Int { pendingExchanges.count }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: memoryFileURL), let file = try? decoder.decode(MemoryFile.self, from: data) {
            items = file.items
            profileSummary = file.profileSummary
            lastConsolidationDate = file.lastConsolidationDate
            pendingExchanges = file.pendingExchanges
            requestsAnsweredWithoutModel = file.requestsAnsweredWithoutModel ?? 0
        }
        if let data = try? Data(contentsOf: proceduresFileURL), let book = try? decoder.decode(ProcedureBook.self, from: data) {
            procedureBook = book
        }
    }

    private func saveMemory() {
        let file = MemoryFile(items: items, profileSummary: profileSummary, lastConsolidationDate: lastConsolidationDate,
                              pendingExchanges: pendingExchanges, requestsAnsweredWithoutModel: requestsAnsweredWithoutModel)
        Self.write(file, to: memoryFileURL)
    }

    private func saveProcedures() {
        Self.write(procedureBook, to: proceduresFileURL)
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
