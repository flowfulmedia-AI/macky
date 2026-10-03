import XCTest
@testable import MackyCore

final class ScreenActionTests: XCTestCase {
    func testParsesClickWithButton() {
        let toolCall = ChatToolCall(identifier: "a", name: "click", argumentsJSON: #"{"screen":1,"x":100,"y":50,"label":"Salvează","button":"double"}"#)
        XCTAssertEqual(ScreenAction(toolCall: toolCall), .click(target: PointingInstruction(screenNumber: 1, x: 100, y: 50, label: "Salvează"), kind: .double))
    }

    func testClickDefaultsToLeftButton() {
        let toolCall = ChatToolCall(identifier: "a", name: "click", argumentsJSON: #"{"x":1,"y":2,"label":"OK"}"#)
        XCTAssertEqual(ScreenAction(toolCall: toolCall), .click(target: PointingInstruction(screenNumber: 1, x: 1, y: 2, label: "OK"), kind: .left))
    }

    func testParsesTypeTextAndPressKeys() {
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "b", name: "type_text", argumentsJSON: #"{"text":"pisici","press_enter":true}"#)),
                       .typeText(text: "pisici", pressEnterAfterwards: true))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "c", name: "press_keys", argumentsJSON: #"{"keys":"cmd+shift+n"}"#)),
                       .pressKeys(KeyCombination(keyCode: 45, modifiers: [.command, .shift], displayName: "⇧⌘N")))
    }

    func testParsesOpenApplicationAndOpenURL() {
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "g", name: "open_app", argumentsJSON: #"{"name":" Spotify "}"#)),
                       .openApplication(name: "Spotify"))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "h", name: "open_url", argumentsJSON: #"{"url":"spotify:search:queen"}"#)),
                       .openURL("spotify:search:queen"))
        XCTAssertNil(ScreenAction(toolCall: ChatToolCall(identifier: "i", name: "open_url", argumentsJSON: #"{"url":"not a url"}"#)))
        XCTAssertEqual(ScreenAction.openApplication(name: "Spotify").userFacingDescription, "Deschide Spotify")
    }

    func testPointAtAndBrokenActionsAreNotActions() {
        XCTAssertNil(ScreenAction(toolCall: ChatToolCall(identifier: "d", name: "point_at", argumentsJSON: #"{"x":1,"y":2}"#)))
        XCTAssertNil(ScreenAction(toolCall: ChatToolCall(identifier: "e", name: "type_text", argumentsJSON: #"{}"#)))
        XCTAssertNil(ScreenAction(toolCall: ChatToolCall(identifier: "f", name: "press_keys", argumentsJSON: #"{"keys":"hyper+q"}"#)))
    }

    func testKeyCombinationParsing() {
        XCTAssertEqual(KeyCombination(parsing: "Enter")?.keyCode, 36)
        XCTAssertEqual(KeyCombination(parsing: "⌘S")?.modifiers, [.command])
        XCTAssertEqual(KeyCombination(parsing: "⌘S")?.keyCode, 1)
        XCTAssertEqual(KeyCombination(parsing: "ctrl + option + down")?.modifiers, [.control, .option])
        XCTAssertEqual(KeyCombination(parsing: "ctrl + option + down")?.keyCode, 125)
        XCTAssertNil(KeyCombination(parsing: ""))
    }
}

final class ToolConversationEncodingTests: XCTestCase {
    func testEncodesAssistantToolCallsAndToolResults() throws {
        let toolCall = ChatToolCall(identifier: "call_9", name: "click", argumentsJSON: #"{"x":1,"y":2,"label":"OK"}"#)
        let messages = [
            ChatMessage(role: .assistant, parts: [], toolCalls: [toolCall]),
            ChatMessage.toolResult(for: toolCall, result: "Clicked.")
        ]
        let data = try OpenRouterRequestBuilder.makeChatCompletionBody(
            modelIdentifier: "m", messages: messages, tools: MackyTool.allCases, coordinateConvention: .imagePixels)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedMessages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertTrue(encodedMessages[0]["content"] is NSNull)
        let encodedToolCalls = try XCTUnwrap(encodedMessages[0]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(encodedToolCalls[0]["id"] as? String, "call_9")
        XCTAssertEqual((encodedToolCalls[0]["function"] as? [String: Any])?["name"] as? String, "click")

        XCTAssertEqual(encodedMessages[1]["role"] as? String, "tool")
        XCTAssertEqual(encodedMessages[1]["tool_call_id"] as? String, "call_9")
        XCTAssertEqual(encodedMessages[1]["content"] as? String, "Clicked.")

        let toolNames = (json["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(toolNames, ["point_at", "click", "type_text", "press_keys", "open_app", "open_url", "run_applescript", "click_element", "spotify", "system_control", "create_event", "list_events", "create_reminder", "list_reminders", "create_note", "arrange_window", "start_background_task", "task_done", "web_search", "fetch_url", "save_file", "finish_task", "remember", "forget", "recall", "replace_selection", "use_skill", "search_files", "read_file", "open_file", "search_gmail", "read_email", "save_email_attachments", "collect_invoices", "search_drive", "read_drive_file", "whatsapp_chats", "whatsapp_read", "whatsapp_search", "whatsapp_send", "search_past_chats", "read_past_chat", "run_agent", "read_error_log"])
        // Google's models reject object parameters without properties.
        for tool in json["tools"] as? [[String: Any]] ?? [] {
            let parameters = (tool["function"] as? [String: Any])?["parameters"] as? [String: Any]
            XCTAssertFalse((parameters?["properties"] as? [String: Any] ?? [:]).isEmpty)
        }
    }

    func testPromptMentionsActionsAndMarkings() {
        XCTAssertTrue(MackyPrompt.systemPrompt(language: .romanian, pointingMode: .toolCall, actionsEnabled: true).contains("type_text"))
        XCTAssertFalse(MackyPrompt.systemPrompt(language: .romanian, pointingMode: .toolCall, actionsEnabled: false).contains("type_text"))
        let text = MackyPrompt.userMessageText(
            question: "Ce e asta?", screenshots: [], frontmostApplication: nil, coordinateConvention: .imagePixels,
            userMarkings: [UserScreenMarking(screenNumber: 1, minimumX: 10, minimumY: 20, maximumX: 110, maximumY: 80)])
        XCTAssertTrue(text.contains("x 10–110, y 20–80"))
    }

    func testModelPointIsInverseOfImagePixelPoint() {
        let imageSize = CGSize(width: 1280, height: 800)
        let pixel = CGPoint(x: 320, y: 600)
        let modelPoint = CoordinateConvention.normalizedTo1000.modelPoint(fromImagePixel: pixel, imagePixelSize: imageSize)
        XCTAssertEqual(modelPoint, CGPoint(x: 250, y: 750))
        XCTAssertEqual(CoordinateConvention.normalizedTo1000.imagePixelPoint(modelX: 250, modelY: 750, imagePixelSize: imageSize), pixel)
    }
}
