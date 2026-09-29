import XCTest
@testable import MackyCore

final class QuickCommandMatcherTests: XCTestCase {
    func testMediaCommands() {
        XCTAssertEqual(QuickCommandMatcher.match("Pune pauză.")?.action, .mediaKey(.playPause))
        XCTAssertEqual(QuickCommandMatcher.match("Macky, următoarea melodie!")?.action, .mediaKey(.nextTrack))
        XCTAssertEqual(QuickCommandMatcher.match("melodia anterioară te rog")?.action, .mediaKey(.previousTrack))
    }

    func testOpenApplication() {
        XCTAssertEqual(QuickCommandMatcher.match("Deschide Spotify.")?.action, .openApplication(name: "spotify"))
        XCTAssertEqual(QuickCommandMatcher.match("Te rog deschide aplicația Visual Studio Code")?.action, .openApplication(name: "visual studio code"))
        XCTAssertEqual(QuickCommandMatcher.match("open safari")?.acknowledgement, "Sigur, deschid acum!")
    }

    func testLeavesComplexRequestsToTheModel() {
        XCTAssertNil(QuickCommandMatcher.match("Pornește prima melodie de la liked songs din Spotify"))
        XCTAssertNil(QuickCommandMatcher.match("deschide un fișier nou"))
        XCTAssertNil(QuickCommandMatcher.match("deschide setările de sunet"))
        XCTAssertNil(QuickCommandMatcher.match("unde e butonul de export?"))
        XCTAssertNil(QuickCommandMatcher.match(""))
    }

    func testRunAppleScriptParsingAndDescription() {
        let toolCall = ChatToolCall(identifier: "a", name: "run_applescript", argumentsJSON: #"{"script":"tell application \"Spotify\" to next track"}"#)
        let action = ScreenAction(toolCall: toolCall)
        XCTAssertEqual(action, .runAppleScript(#"tell application "Spotify" to next track"#))
        XCTAssertEqual(action?.userFacingDescription, "Controlează Spotify direct")
        XCTAssertNil(ScreenAction(toolCall: ChatToolCall(identifier: "b", name: "task_done", argumentsJSON: "{}")))
    }

    func testReasoningCanBeDisabled() throws {
        let data = try OpenRouterRequestBuilder.makeChatCompletionBody(
            modelIdentifier: "m", messages: [ChatMessage(role: .user, text: "hi")], tools: [], coordinateConvention: .imagePixels, disableReasoning: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
    }
}
