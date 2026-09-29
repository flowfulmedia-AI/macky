import XCTest
@testable import MackyCore

final class ServerSentEventTests: XCTestCase {
    func testParsesDataDoneAndComments() {
        XCTAssertEqual(ServerSentEventLineParser.parse("data: {\"a\":1}"), .data("{\"a\":1}"))
        XCTAssertEqual(ServerSentEventLineParser.parse("data: [DONE]"), .done)
        XCTAssertEqual(ServerSentEventLineParser.parse(": OPENROUTER PROCESSING"), .ignorable)
        XCTAssertEqual(ServerSentEventLineParser.parse(""), .ignorable)
    }
}

final class OpenRouterStreamDecoderTests: XCTestCase {
    func testEmitsTextDeltas() throws {
        var decoder = OpenRouterStreamDecoder()
        let events = try decoder.consume(dataPayload: #"{"choices":[{"delta":{"content":"Salut"},"finish_reason":null}]}"#)
        XCTAssertEqual(events, [.textDelta("Salut")])
    }

    func testAccumulatesFragmentedToolCallUntilFinish() throws {
        var decoder = OpenRouterStreamDecoder()
        var events: [LLMStreamEvent] = []
        events += try decoder.consume(dataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"point_at","arguments":""}}]}}]}"#)
        events += try decoder.consume(dataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"screen\":1,\"x\":"}}]}}]}"#)
        events += try decoder.consume(dataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"120,\"y\":40,\"label\":\"Export\"}"}}]}}]}"#)
        XCTAssertEqual(events, [])
        events += try decoder.consume(dataPayload: #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        XCTAssertEqual(events, [
            .toolCall(ChatToolCall(identifier: "c1", name: "point_at", argumentsJSON: #"{"screen":1,"x":120,"y":40,"label":"Export"}"#)),
            .finished(reason: "tool_calls")
        ])
        XCTAssertEqual(decoder.finish(), [], "tool calls must not be emitted twice")
    }

    func testMultipleToolCallsKeepOrder() throws {
        var decoder = OpenRouterStreamDecoder()
        _ = try decoder.consume(dataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"point_at","arguments":"{\"x\":2,\"y\":2}"}},{"index":0,"function":{"name":"point_at","arguments":"{\"x\":1,\"y\":1}"}}]}}]}"#)
        let events = decoder.finish()
        XCTAssertEqual(events, [
            .toolCall(ChatToolCall(identifier: "call_0", name: "point_at", argumentsJSON: #"{"x":1,"y":1}"#)),
            .toolCall(ChatToolCall(identifier: "call_1", name: "point_at", argumentsJSON: #"{"x":2,"y":2}"#))
        ])
    }

    func testParsesUsageWithCost() throws {
        var decoder = OpenRouterStreamDecoder()
        let events = try decoder.consume(dataPayload: #"{"choices":[],"usage":{"prompt_tokens":1500,"completion_tokens":60,"cost":0.00123}}"#)
        XCTAssertEqual(events, [.usage(TokenUsage(promptTokens: 1500, completionTokens: 60, costInCredits: 0.00123))])
    }

    func testMidStreamErrorThrows() {
        var decoder = OpenRouterStreamDecoder()
        XCTAssertThrowsError(try decoder.consume(dataPayload: #"{"error":{"code":502,"message":"Provider down"}}"#)) { error in
            XCTAssertEqual(error as? OpenRouterAPIError, OpenRouterAPIError(httpStatusCode: 502, message: "Provider down"))
        }
    }

    func testHTTPErrorParsingAndToolDetection() {
        let error = OpenRouterAPIError.fromHTTPResponse(statusCode: 404, body: #"{"error":{"message":"No endpoints found that support tool use.","code":404}}"#)
        XCTAssertEqual(error.message, "No endpoints found that support tool use.")
        XCTAssertTrue(error.indicatesToolCallingUnsupported)
        XCTAssertFalse(OpenRouterAPIError.fromHTTPResponse(statusCode: 401, body: "nope").indicatesToolCallingUnsupported)
        XCTAssertTrue(OpenRouterAPIError.fromHTTPResponse(statusCode: 401, body: "nope").indicatesInvalidAPIKey)
    }
}

final class RequestBuilderTests: XCTestCase {
    func testBuildsVisionMessageWithToolsAndUsage() throws {
        let messages = [
            ChatMessage(role: .system, text: "sys"),
            ChatMessage(role: .user, parts: [.text("Unde e Export?"), .jpegImage(base64EncodedData: "QUJD")])
        ]
        let data = try OpenRouterRequestBuilder.makeChatCompletionBody(
            modelIdentifier: "anthropic/claude-sonnet", messages: messages,
            tools: [.pointAt], coordinateConvention: .imagePixels)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "anthropic/claude-sonnet")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual((json["usage"] as? [String: Any])?["include"] as? Bool, true)

        let encodedMessages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(encodedMessages[0]["content"] as? String, "sys")
        let userContent = try XCTUnwrap(encodedMessages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent[0]["type"] as? String, "text")
        let imageURL = (userContent[1]["image_url"] as? [String: Any])?["url"] as? String
        XCTAssertEqual(imageURL, "data:image/jpeg;base64,QUJD")

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual((tools[0]["function"] as? [String: Any])?["name"] as? String, "point_at")
    }

    func testOmitsToolsWhenDisabled() throws {
        let data = try OpenRouterRequestBuilder.makeChatCompletionBody(
            modelIdentifier: "m", messages: [ChatMessage(role: .user, text: "hi")],
            tools: [], coordinateConvention: .imagePixels)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["tools"])
        XCTAssertNil(json["tool_choice"])
    }
}
