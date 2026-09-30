import XCTest
@testable import MackyCore

final class EdgeTTSTests: XCTestCase {
    func testSecMSGECInputRoundsToFiveMinutes() {
        // 2026-01-01T00:02:30Z → rounded down to 00:00:00.
        let date = Date(timeIntervalSince1970: 1_767_225_750)
        let rounded = UInt64(1_767_225_600 + 11_644_473_600) * 10_000_000
        XCTAssertEqual(EdgeTTSProtocol.secMSGECInput(now: date), "\(rounded)\(EdgeTTSProtocol.trustedClientToken)")
    }

    func testMessages() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(EdgeTTSProtocol.timestamp(date), "Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)")
        let ssml = EdgeTTSProtocol.ssmlMessage(text: "Tom & Jerry <3", voice: "ro-RO-AlinaNeural", ratePercent: -10, pitchHertz: 0, requestIdentifier: "abc", now: date)
        XCTAssertTrue(ssml.hasPrefix("X-RequestId:abc\r\nContent-Type:application/ssml+xml\r\n"))
        XCTAssertTrue(ssml.contains("Path:ssml\r\n\r\n<speak"))
        XCTAssertTrue(ssml.contains("rate='-10%'"))
        XCTAssertTrue(ssml.contains("pitch='+0Hz'"))
        XCTAssertTrue(ssml.contains("Tom &amp; Jerry &lt;3"))
        XCTAssertTrue(EdgeTTSProtocol.configurationMessage(now: date).contains("audio-24khz-48kbitrate-mono-mp3"))
        let url = EdgeTTSProtocol.webSocketURL(secMSGEC: "ABC", connectionIdentifier: "123").absoluteString
        XCTAssertTrue(url.hasPrefix("wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken="))
        XCTAssertTrue(url.contains("Sec-MS-GEC=ABC"))
    }

    func testBinaryFrameParsing() {
        let header = Data("X-RequestId:1\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n".utf8)
        var frame = Data([UInt8(header.count >> 8), UInt8(header.count & 0xFF)])
        frame.append(header)
        frame.append(Data([1, 2, 3]))
        XCTAssertEqual(EdgeTTSProtocol.audioPayload(fromBinaryFrame: frame), Data([1, 2, 3]))
        XCTAssertNil(EdgeTTSProtocol.audioPayload(fromBinaryFrame: Data([0, 50, 1])))
        XCTAssertTrue(EdgeTTSProtocol.isTurnEnd(textFrame: "X-RequestId:1\r\nPath:turn.end\r\n\r\n{}"))
    }
}

final class SkillTests: XCTestCase {
    func testParseFrontMatter() {
        let markdown = """
        ---
        name: email-client
        description: "Scrie mailuri către clienți în stilul meu."
        license: MIT
        ---
        # Email

        Folosește un ton cald.
        """
        let skill = SkillParser.parse(markdown: markdown, fallbackName: "folder", sourcePath: "/x")
        XCTAssertEqual(skill?.name, "email-client")
        XCTAssertEqual(skill?.description, "Scrie mailuri către clienți în stilul meu.")
        XCTAssertEqual(skill?.instructions, "# Email\n\nFolosește un ton cald.")
    }

    func testBlockDescriptionAndFallbacks() {
        let block = "---\nname: oferte\ndescription: >\n  Creează oferte\n  pentru clienți.\n---\nPași."
        XCTAssertEqual(SkillParser.parse(markdown: block, fallbackName: "x", sourcePath: "")?.description, "Creează oferte pentru clienți.")
        let plain = SkillParser.parse(markdown: "# Titlu\nPrima linie utilă.\nRest.", fallbackName: "postari", sourcePath: "")
        XCTAssertEqual(plain?.name, "postari")
        XCTAssertEqual(plain?.description, "Prima linie utilă.")
        XCTAssertNil(SkillParser.parse(markdown: "   ", fallbackName: "gol", sourcePath: ""))
    }

    func testCatalogAndFind() {
        let skills = [
            SkillDefinition(name: "email-client", description: "Mailuri.", instructions: String(repeating: "a", count: 20_000), sourcePath: ""),
            SkillDefinition(name: "Postări LinkedIn", description: "Postări.", instructions: "b", sourcePath: "")
        ]
        let section = SkillCatalog.promptSection(for: skills)!
        XCTAssertTrue(section.contains("- email-client: Mailuri."))
        XCTAssertNil(SkillCatalog.promptSection(for: []))
        XCTAssertEqual(SkillCatalog.find("Email Client", in: skills)?.name, "email-client")
        XCTAssertEqual(SkillCatalog.find("postari linkedin", in: skills)?.name, "Postări LinkedIn")
        XCTAssertNil(SkillCatalog.find("facturi", in: skills))
        XCTAssertTrue(SkillCatalog.toolResult(for: skills[0]).hasSuffix("[…truncated]"))
    }

    func testNewToolCalls() {
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "1", name: "use_skill", argumentsJSON: #"{"name":"email"}"#)), .useSkill(name: "email"))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "2", name: "replace_selection", argumentsJSON: #"{"text":"Bună ziua"}"#)), .replaceSelection(text: "Bună ziua"))
        let search = ScreenAction(toolCall: ChatToolCall(identifier: "3", name: "web_search", argumentsJSON: #"{"query":"vremea Cluj"}"#))
        XCTAssertEqual(search, .webSearch(query: "vremea Cluj"))
        XCTAssertEqual(search?.needsNoScreen, true)
        XCTAssertEqual(search?.returnsInformation, true)
        XCTAssertEqual(ScreenAction.replaceSelection(text: "x").needsNoScreen, false)
    }

    func testSelectedTextInPrompt() {
        let context = FrontmostApplicationContext(applicationName: "Gmail", windowTitle: nil, selectedText: "Salut, ce faci?")
        let text = MackyPrompt.userMessageText(question: "rescrie mai formal", screenshots: [], frontmostApplication: context, coordinateConvention: .imagePixels)
        XCTAssertTrue(text.contains("Text the user has selected:\n\"\"\"\nSalut, ce faci?\n\"\"\""))
        XCTAssertTrue(MackyPrompt.systemPrompt(language: .romanian, pointingMode: .toolCall, actionsEnabled: true).contains("replace_selection"))
    }

    func testWritingIntent() {
        XCTAssertTrue(WritingIntent.mentionsText("Rescrie textul ăsta mai politicos"))
        XCTAssertTrue(WritingIntent.mentionsText("tradu în engleză"))
        XCTAssertFalse(WritingIntent.mentionsText("pune Numb pe Spotify"))
    }
}

final class FollowUpTests: XCTestCase {
    private let sampleRate = 16_000.0

    private func detector(_ levels: [Float]) -> SpeechEndpointDetector {
        var detector = SpeechEndpointDetector()
        for level in levels { detector.append(chunkLevel: level, sampleCount: 1600) }
        return detector
    }

    func testDecisions() {
        let silence = detector(Array(repeating: 0.001, count: 20))
        XCTAssertEqual(FollowUpListeningPolicy.decide(detector: silence, elapsedSeconds: 2, window: 5, sampleRate: sampleRate), .keepListening)
        XCTAssertEqual(FollowUpListeningPolicy.decide(detector: silence, elapsedSeconds: 5.1, window: 5, sampleRate: sampleRate), .giveUp)

        let talking = detector(Array(repeating: 0.001, count: 5) + Array(repeating: 0.1, count: 10))
        XCTAssertEqual(FollowUpListeningPolicy.decide(detector: talking, elapsedSeconds: 7, window: 5, sampleRate: sampleRate), .keepListening)

        let finished = detector(Array(repeating: 0.1, count: 10) + Array(repeating: 0.001, count: 9))
        XCTAssertEqual(FollowUpListeningPolicy.decide(detector: finished, elapsedSeconds: 2, window: 5, sampleRate: sampleRate), .finish)
    }

    func testWindowAndDismissal() {
        XCTAssertEqual(FollowUpListeningPolicy.listeningWindow(afterAnswer: "Vrei să-l trimit?"), 8)
        XCTAssertEqual(FollowUpListeningPolicy.listeningWindow(afterAnswer: "Mâine ai două întâlniri."), 5)
        XCTAssertTrue(FollowUpListeningPolicy.isDismissal("Mulțumesc!"))
        XCTAssertTrue(FollowUpListeningPolicy.isDismissal("gata."))
        XCTAssertFalse(FollowUpListeningPolicy.isDismissal("și poimâine?"))
    }
}
