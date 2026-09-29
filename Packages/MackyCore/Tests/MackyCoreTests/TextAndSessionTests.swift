import XCTest
@testable import MackyCore

final class SentenceSegmenterTests: XCTestCase {
    func testSplitsStreamedSentences() {
        var segmenter = SentenceSegmenter()
        var sentences: [String] = []
        for chunk in ["Salut! Apasă pe ", "butonul Export. Apoi alege", " formatul MP4"] {
            sentences += segmenter.append(chunk)
        }
        XCTAssertEqual(sentences, ["Salut!", "Apasă pe butonul Export."])
        XCTAssertEqual(segmenter.flush(), "Apoi alege formatul MP4")
    }

    func testDoesNotSplitDecimalsFileNamesOrAbbreviations() {
        var segmenter = SentenceSegmenter()
        let sentences = segmenter.append("Versiunea 3.5 e în fișier.txt, de ex. aici. Gata ")
        XCTAssertEqual(sentences, ["Versiunea 3.5 e în fișier.txt, de ex. aici."])
    }

    func testWaitsWhenPunctuationIsLastCharacter() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(segmenter.append("Da."), [])
        XCTAssertEqual(segmenter.append(" Nu."), ["Da."])
        XCTAssertEqual(segmenter.flush(), "Nu.")
    }

    func testNewlinesEndSentences() {
        var segmenter = SentenceSegmenter()
        XCTAssertEqual(segmenter.append("Primul pas\nAl doilea"), ["Primul pas"])
    }
}

final class SpeechTextCleanerTests: XCTestCase {
    func testRemovesMarkdown() {
        let cleaned = SpeechTextCleaner.cleanForSpeech("## Pași\n- Apasă **Export** și `Cmd+E`\n1. Vezi [ghidul](https://x.y/z) *acum*")
        XCTAssertEqual(cleaned, "Pași\nApasă Export și Cmd+E\nVezi ghidul acum")
    }
}

final class ConversationHistoryTests: XCTestCase {
    func testKeepsOnlyRecentExchangesAndImagesOnLatestQuestion() {
        var history = ConversationHistory(maximumRememberedExchanges: 2)
        history.record(userText: "q1", assistantText: "a1")
        history.record(userText: "q2", assistantText: "a2")
        history.record(userText: "q3", assistantText: "")
        let messages = history.messagesForRequest(systemPrompt: "sys", currentUserParts: [.text("q4"), .jpegImage(base64EncodedData: "x")])
        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant, .user, .assistant, .user])
        XCTAssertEqual(messages[1].plainText, "q2")
        XCTAssertEqual(messages[4].plainText, "(fără răspuns)")
        XCTAssertEqual(messages.filter(\.containsImage).count, 1)
        XCTAssertTrue(messages.last!.containsImage)
    }

    func testCostTracker() {
        var tracker = SessionCostTracker()
        tracker.record(TokenUsage(promptTokens: 100, completionTokens: 10, costInCredits: 0.002))
        tracker.record(TokenUsage(promptTokens: 50, completionTokens: 5, costInCredits: nil))
        XCTAssertEqual(tracker.requestCount, 2)
        XCTAssertEqual(tracker.totalCostInCredits, 0.002, accuracy: 1e-9)
        XCTAssertNil(tracker.lastRequestCostInCredits)
        XCTAssertEqual(SessionCostTracker.formatCredits(0.002), "$0.0020")
        XCTAssertEqual(SessionCostTracker.formatCredits(1.5), "$1.50")
    }
}

final class PromptTests: XCTestCase {
    func testUserMessageDescribesScreensAndApp() {
        let text = MackyPrompt.userMessageText(
            question: "Unde export?",
            screenshots: [ScreenshotDescription(screenNumber: 1, displayName: "Built-in", imagePixelSize: CGSize(width: 1280, height: 831), containsMouseCursor: true)],
            frontmostApplication: FrontmostApplicationContext(applicationName: "Figma", windowTitle: "Design"),
            coordinateConvention: .imagePixels)
        XCTAssertTrue(text.contains("Active app: Figma — window \"Design\"."))
        XCTAssertTrue(text.contains("Screenshot 1 (Built-in): 1280x831 pixels"))
        XCTAssertTrue(text.contains("mouse cursor is on this screen"))
        XCTAssertTrue(text.hasSuffix("User: Unde export?"))
    }

    func testSystemPromptMentionsPointingMode() {
        XCTAssertTrue(MackyPrompt.systemPrompt(language: .romanian, pointingMode: .toolCall).contains("point_at"))
        XCTAssertTrue(MackyPrompt.systemPrompt(language: .romanian, pointingMode: .textTag).contains("[[point:"))
    }
}

final class ModelCatalogTests: XCTestCase {
    let sampleResponse = """
    {"data":[
      {"id":"google/gemini-2.5-flash","name":"Gemini 2.5 Flash","created":100,"architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools","max_tokens"],"pricing":{"prompt":"0.0000003","completion":"0.0000025"}},
      {"id":"google/gemini-3-flash","name":"Gemini 3 Flash","created":200,"architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools"],"pricing":{"prompt":"0.0000005","completion":"0.000003"}},
      {"id":"google/gemini-3-flash-image","name":"Image gen","created":300,"architecture":{"input_modalities":["text","image"]},"supported_parameters":[],"pricing":{"prompt":"0","completion":"0"}},
      {"id":"anthropic/claude-sonnet-4.5","name":"Claude Sonnet","created":150,"architecture":{"input_modalities":["text","image"]},"supported_parameters":["tools"],"pricing":{"prompt":"0.000003","completion":"0.000015"}},
      {"id":"meta/text-only","name":"Text","created":400,"architecture":{"input_modalities":["text"]},"supported_parameters":["tools"],"pricing":{"prompt":"0","completion":"0"}}
    ]}
    """

    func testParsesAndPicksDefaults() throws {
        let models = try ModelCatalog.parseModelsResponse(Data(sampleResponse.utf8))
        XCTAssertEqual(models.count, 5)
        let flash = try XCTUnwrap(models.first { $0.id == "google/gemini-2.5-flash" })
        XCTAssertTrue(flash.acceptsImages)
        XCTAssertTrue(flash.supportsToolCalling)
        XCTAssertEqual(flash.inputPricePerMillionTokens ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(ModelCatalog.defaultFastModel(in: models)?.id, "google/gemini-3-flash")
        XCTAssertEqual(ModelCatalog.defaultPowerfulModel(in: models)?.id, "anthropic/claude-sonnet-4.5")
        XCTAssertFalse(models.first { $0.id == "meta/text-only" }!.acceptsImages)
    }
}

final class HotkeyStateMachineTests: XCTestCase {
    func testPressAndReleaseTalk() {
        var machine = HotkeyStateMachine(talkCombination: [.control, .option], dictationCombination: [.control, .shift])
        XCTAssertEqual(machine.handleModifiersChanged([.control]), [])
        XCTAssertEqual(machine.handleModifiersChanged([.control, .option]), [.pressed(.talk)])
        XCTAssertEqual(machine.handleModifiersChanged([.option]), [.released(.talk)])
        XCTAssertEqual(machine.handleModifiersChanged([]), [])
    }

    func testRegularKeyCancelsAndBlocksUntilAllReleased() {
        var machine = HotkeyStateMachine(talkCombination: [.control, .option], dictationCombination: [.control, .shift])
        XCTAssertEqual(machine.handleModifiersChanged([.control, .shift]), [.pressed(.dictate)])
        XCTAssertEqual(machine.handleRegularKeyPressed(), [.cancelled(.dictate)])
        XCTAssertEqual(machine.handleModifiersChanged([.control]), [])
        XCTAssertEqual(machine.handleModifiersChanged([.control, .shift]), [], "must not restart before full release")
        XCTAssertEqual(machine.handleModifiersChanged([]), [])
        XCTAssertEqual(machine.handleModifiersChanged([.control, .shift]), [.pressed(.dictate)])
    }

    func testExtraModifierCancels() {
        var machine = HotkeyStateMachine(talkCombination: [.control, .option], dictationCombination: nil)
        XCTAssertEqual(machine.handleModifiersChanged([.control, .option]), [.pressed(.talk)])
        XCTAssertEqual(machine.handleModifiersChanged([.control, .option, .command]), [.cancelled(.talk)])
        XCTAssertEqual(machine.handleRegularKeyPressed(), [])
    }
}
