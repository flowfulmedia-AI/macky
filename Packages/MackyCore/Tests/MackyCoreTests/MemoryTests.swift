import XCTest
@testable import MackyCore

final class MemoryTests: XCTestCase {
    private func item(_ kind: MemoryKind, _ subject: String, _ content: String) -> MemoryItem {
        MemoryItem(kind: kind, subject: subject, content: content, source: .learned)
    }

    func testKeywordsStemAndDropStopwords() {
        XCTAssertEqual(MemoryText.keywords(of: "Clientului și clienții"), ["client", "client"])
        XCTAssertEqual(MemoryText.keywords(of: "volumul la 5"), ["volumu", "5"])
    }

    func testRetrievalFindsClientByName() {
        let items = [
            item(.person, "Andrei Popescu", "Client, firma Nordic Build; contractul e în Drive la Clienți/Nordic."),
            item(.preference, "Stil mailuri", "Mailurile către clienți: scurte, fără formule pompoase."),
            item(.location, "Facturi", "Facturile sunt în Google Drive, folderul Contabilitate/2026."),
            item(.fact, "Pisica", "Utilizatorul are o pisică pe nume Mura.")
        ]
        let matches = MemoryRetriever.rank(query: "unde e contractul lui Andrei?", items: items)
        XCTAssertEqual(matches.first?.item.subject, "Andrei Popescu")
        XCTAssertFalse(matches.contains { $0.item.subject == "Pisica" })

        let invoiceMatches = MemoryRetriever.rank(query: "Unde găsesc facturile?", items: items)
        XCTAssertEqual(invoiceMatches.first?.item.subject, "Facturi")
    }

    func testRetrievalUsesVectorsWhenKeywordsMiss() {
        let invoices = item(.location, "Facturi", "Folderul Contabilitate din Drive.")
        let cat = item(.fact, "Pisica", "Mura.")
        let matches = MemoryRetriever.rank(
            query: "unde țin chitanțele",
            items: [invoices, cat],
            queryVector: [1, 0, 0],
            vectorsByIdentifier: [invoices.id: [0.95, 0.1, 0], cat.id: [0, 1, 0]]
        )
        XCTAssertEqual(matches.map(\.item.subject), ["Facturi"])
    }

    func testContextBlockRespectsBudgetAndDeduplicates() {
        let pinned = item(.profile, "Nume", "Utilizatorul se numește Alex.")
        let many = (0..<50).map { item(.fact, "Fapt \($0)", String(repeating: "x", count: 100)) }
        let block = MemoryContextBuilder.contextBlock(profileSummary: "Antreprenor.", pinnedItems: [pinned], relevantItems: [pinned] + many, characterBudget: 600)!
        XCTAssertTrue(block.contains("About the user: Antreprenor."))
        XCTAssertEqual(block.components(separatedBy: "Utilizatorul se numește Alex.").count, 2)
        XCTAssertLessThan(block.count, 900)
        XCTAssertNil(MemoryContextBuilder.contextBlock(profileSummary: nil, pinnedItems: [], relevantItems: []))
    }

    func testCuratorSignals() {
        XCTAssertTrue(MemoryCurator.shouldCurateImmediately(question: "Ține minte că Andrei e clientul meu", hadFailure: false))
        XCTAssertTrue(MemoryCurator.shouldCurateImmediately(question: "Nu asta, am zis Chrome", hadFailure: false))
        XCTAssertTrue(MemoryCurator.shouldCurateImmediately(question: "deschide ceva", hadFailure: true))
        XCTAssertFalse(MemoryCurator.shouldCurateImmediately(question: "Ce vreme e azi?", hadFailure: false))
    }

    func testParseOperations() {
        let existing = UUID()
        let response = """
        ```json
        [{"op":"add","kind":"person","subject":"Ioana","content":"Clientă, agenția Lumen."},
         {"op":"update","id":"\(existing.uuidString)","content":"Nou"},
         {"op":"delete","id":"\(UUID().uuidString)"},
         {"op":"add","kind":"weird","content":"x"}]
        ```
        """
        let operations = MemoryCurator.parseOperations(from: response, knownIdentifiers: [existing])
        XCTAssertEqual(operations, [
            .add(kind: .person, subject: "Ioana", content: "Clientă, agenția Lumen."),
            .update(identifier: existing, subject: nil, content: "Nou")
        ])
        XCTAssertEqual(MemoryCurator.parseOperations(from: "Nimic de reținut.", knownIdentifiers: []), [])
        XCTAssertEqual(MemoryCurator.parseOperations(from: "[]", knownIdentifiers: []), [])
    }

    func testParseConsolidationDropsAdds() {
        let existing = UUID()
        let response = #"{"profile_summary":"Alex, antreprenor.","operations":[{"op":"delete","id":"\#(existing.uuidString)"},{"op":"add","kind":"fact","subject":"a","content":"b"}]}"#
        let result = MemoryCurator.parseConsolidation(from: response, knownIdentifiers: [existing])
        XCTAssertEqual(result.profileSummary, "Alex, antreprenor.")
        XCTAssertEqual(result.operations, [.delete(identifier: existing)])
    }

    func testMemoryToolCalls() {
        let remember = ChatToolCall(identifier: "1", name: "remember", argumentsJSON: #"{"kind":"person","subject":"Ioana","content":"Clientă Lumen"}"#)
        XCTAssertEqual(ScreenAction(toolCall: remember), .remember(kind: .person, subject: "Ioana", content: "Clientă Lumen"))
        XCTAssertEqual(ScreenAction(toolCall: remember)?.isMemoryOperation, true)
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "2", name: "recall", argumentsJSON: #"{"query":"Ioana"}"#)), .recall(query: "Ioana"))
        XCTAssertNil(ScreenAction(toolCall: ChatToolCall(identifier: "3", name: "forget", argumentsJSON: "{}")))
    }

    func testPromptCachingMarksSystemMessage() throws {
        let body = try OpenRouterRequestBuilder.makeChatCompletionBody(
            modelIdentifier: "anthropic/claude-sonnet",
            messages: [ChatMessage(role: .system, text: "SYS"), ChatMessage(role: .user, text: "hi")],
            tools: [], coordinateConvention: .imagePixels, cacheSystemPrompt: true
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemContent = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(systemContent[0]["text"] as? String, "SYS")
        XCTAssertNotNil(systemContent[0]["cache_control"])
        XCTAssertEqual(messages[1]["content"] as? String, "hi")
        XCTAssertTrue(OpenRouterRequestBuilder.needsExplicitPromptCaching(modelIdentifier: "anthropic/claude-sonnet-4.5"))
        XCTAssertFalse(OpenRouterRequestBuilder.needsExplicitPromptCaching(modelIdentifier: "google/gemini-2.5-flash"))
    }

    func testMemoryContextGoesIntoUserMessage() {
        let text = MackyPrompt.userMessageText(question: "Q", screenshots: [], frontmostApplication: nil, coordinateConvention: .imagePixels, memoryContext: "MEM")
        XCTAssertTrue(text.contains("MEM"))
        XCTAssertTrue(MackyPrompt.systemPrompt(language: .romanian, pointingMode: .toolCall, memoryEnabled: true).contains("recall"))
    }
}

final class ProcedureTests: XCTestCase {
    private let spotifyCall = ChatToolCall(identifier: "a", name: "spotify", argumentsJSON: #"{"query":"lofi","action":"play"}"#)
    private let doneCall = ChatToolCall(identifier: "b", name: "task_done", argumentsJSON: "{}")

    func testPromotionAfterTwoIdenticalRuns() {
        var book = ProcedureBook()
        XCTAssertNil(book.recordSuccessfulRun(request: "Pune-mi muzica de lucru", toolCalls: [spotifyCall, doneCall]))
        XCTAssertNil(book.match("pune-mi muzica de lucru"))
        // Same arguments in another key order are the same call.
        let reordered = ChatToolCall(identifier: "c", name: "spotify", argumentsJSON: #"{ "action": "play", "query": "lofi" }"#)
        let procedure = book.recordSuccessfulRun(request: "pune-mi muzica de lucru!", toolCalls: [reordered])
        XCTAssertNotNil(procedure)
        XCTAssertEqual(procedure?.toolCalls.count, 1)
        XCTAssertEqual(book.match("Pune-mi muzica de lucru")?.id, procedure?.id)
        XCTAssertNil(book.match("pune-mi muzica de relaxare"))
        XCTAssertTrue(book.candidates.isEmpty)
    }

    func testDifferentSolutionRestartsCounting() {
        var book = ProcedureBook()
        book.recordSuccessfulRun(request: "muzica de lucru", toolCalls: [spotifyCall])
        let other = ChatToolCall(identifier: "x", name: "spotify", argumentsJSON: #"{"action":"play","query":"jazz"}"#)
        XCTAssertNil(book.recordSuccessfulRun(request: "muzica de lucru", toolCalls: [other]))
        XCTAssertNotNil(book.recordSuccessfulRun(request: "muzica de lucru", toolCalls: [other]))
    }

    func testNonCacheableRequests() {
        let click = ChatToolCall(identifier: "a", name: "click", argumentsJSON: #"{"screen":1,"x":1,"y":2,"label":"OK"}"#)
        XCTAssertFalse(ProcedureBook.isCacheable(request: "apasă OK", toolCalls: [click]))
        XCTAssertFalse(ProcedureBook.isCacheable(request: "pune asta pe Spotify", toolCalls: [spotifyCall]))
        XCTAssertFalse(ProcedureBook.isCacheable(request: "nu asta, pune lofi", toolCalls: [spotifyCall]))
        XCTAssertFalse(ProcedureBook.isCacheable(request: "gata", toolCalls: [doneCall]))
        XCTAssertTrue(ProcedureBook.isCacheable(request: "pune lofi", toolCalls: [spotifyCall, doneCall]))
    }

    func testFailuresDisableProcedure() throws {
        var book = ProcedureBook()
        book.recordSuccessfulRun(request: "muzica de lucru", toolCalls: [spotifyCall])
        let procedure = try XCTUnwrap(book.recordSuccessfulRun(request: "muzica de lucru", toolCalls: [spotifyCall]))
        XCTAssertFalse(book.recordFailure(of: procedure.id))
        XCTAssertTrue(book.recordFailure(of: procedure.id))
        XCTAssertNil(book.match("muzica de lucru"))
        book.setEnabled(true, for: procedure.id)
        XCTAssertNotNil(book.match("muzica de lucru"))
    }

    func testHistorySearch() {
        let old = HistoryEntry(date: Date(timeIntervalSince1970: 100), question: "Pune Numb", answer: "Sigur!", route: .quickCommand)
        let new = HistoryEntry(date: Date(timeIntervalSince1970: 200), question: "Ce am mâine?", answer: "Ai o întâlnire cu Andrei.", route: .model)
        XCTAssertEqual(HistorySearch.filter([old, new], query: "").map(\.question), ["Ce am mâine?", "Pune Numb"])
        XCTAssertEqual(HistorySearch.filter([old, new], query: "intalnire andrei").map(\.question), ["Ce am mâine?"])
    }
}
