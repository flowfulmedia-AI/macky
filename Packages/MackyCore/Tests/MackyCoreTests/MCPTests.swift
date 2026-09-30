import XCTest
@testable import MackyCore

final class MCPTests: XCTestCase {
    func testRequests() throws {
        let initialize = try JSONSerialization.jsonObject(with: MCPProtocol.initializeRequest(identifier: 1)) as! [String: Any]
        XCTAssertEqual(initialize["method"] as? String, "initialize")
        XCTAssertEqual((initialize["params"] as? [String: Any])?["protocolVersion"] as? String, MCPProtocol.protocolVersion)
        let call = try JSONSerialization.jsonObject(with: MCPProtocol.callToolRequest(identifier: 7, name: "create_task", argumentsJSON: #"{"title":"Sun la contabil"}"#)) as! [String: Any]
        let params = call["params"] as! [String: Any]
        XCTAssertEqual(params["name"] as? String, "create_task")
        XCTAssertEqual((params["arguments"] as? [String: Any])?["title"] as? String, "Sun la contabil")
    }

    func testResponsesFromJSONAndEventStream() throws {
        let json = Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_tasks","description":"Lists tasks","inputSchema":{"type":"object","properties":{"status":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"delete_task","description":"Deletes"}],"nextCursor":"abc"}}"#.utf8)
        let result = try MCPProtocol.response(withIdentifier: 2, in: json, contentType: "application/json")
        let parsed = MCPProtocol.parseTools(fromResult: result)
        XCTAssertEqual(parsed.tools.map(\.name), ["list_tasks", "delete_task"])
        XCTAssertEqual(parsed.nextCursor, "abc")
        XCTAssertFalse(parsed.tools[0].needsConfirmation)
        XCTAssertTrue(parsed.tools[1].needsConfirmation)

        let stream = Data("event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Task creat\"}]}}\r\n\r\n".utf8)
        let callResult = try MCPProtocol.response(withIdentifier: 3, in: stream, contentType: "text/event-stream; charset=utf-8")
        XCTAssertEqual(MCPProtocol.toolResultText(fromResult: callResult).text, "Task creat")

        let error = Data(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Unknown tool"}}"#.utf8)
        XCTAssertThrowsError(try MCPProtocol.response(withIdentifier: 4, in: error, contentType: "application/json"))
        XCTAssertThrowsError(try MCPProtocol.response(withIdentifier: 5, in: json, contentType: "application/json"))
    }

    func testToolResultFallbacks() {
        let structured = MCPProtocol.toolResultText(fromResult: ["structuredContent": ["count": 2], "isError": true])
        XCTAssertEqual(structured.text, #"{"count":2}"#)
        XCTAssertTrue(structured.isError)
        XCTAssertEqual(MCPProtocol.toolResultText(fromResult: [:]).text, "Done (no output).")
    }

    func testNamingAndDefinitions() {
        XCTAssertEqual(MCPToolNaming.modelToolName(serverName: "Flowts", toolName: "create-task"), "mcp_flowts__create_task")
        XCTAssertEqual(MCPToolNaming.modelToolName(serverName: "Aplicația mea", toolName: "x"), "mcp_aplicatia_mea__x")
        XCTAssertLessThanOrEqual(MCPToolNaming.modelToolName(serverName: "A", toolName: String(repeating: "t", count: 100)).count, 64)
        let tool = MCPToolDescriptor(name: "list_projects", title: nil, description: "Lists projects", inputSchemaJSON: #"{"$schema":"x","type":"object"}"#, isReadOnly: true, isDestructive: false)
        let definition = MCPToolNaming.toolDefinition(serverName: "Flowts", tool: tool)
        let function = definition["function"] as! [String: Any]
        let parameters = function["parameters"] as! [String: Any]
        XCTAssertNil(parameters["$schema"])
        XCTAssertFalse((parameters["properties"] as! [String: Any]).isEmpty)
        XCTAssertEqual(function["description"] as? String, "[Flowts] Lists projects")
    }

    func testPromptAndBody() throws {
        let section = MackyPrompt.connectedAppsSection(apps: [(name: "Flowts", instructions: "Taskurile mele.")])!
        XCTAssertTrue(section.contains("- Flowts: Taskurile mele."))
        XCTAssertNil(MackyPrompt.connectedAppsSection(apps: []))
        let extra = MCPToolNaming.toolDefinition(serverName: "Flowts", tool: MCPToolDescriptor(name: "a", title: nil, description: "", inputSchemaJSON: "{}", isReadOnly: false, isDestructive: false))
        let body = try OpenRouterRequestBuilder.makeChatCompletionBody(modelIdentifier: "m", messages: [ChatMessage(role: .user, text: "hi")], tools: [.taskDone],
                                                                       coordinateConvention: .imagePixels, extraToolDefinitions: [extra])
        let tools = (try JSONSerialization.jsonObject(with: body) as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(ScreenAction.externalTool(serverName: "Flowts", toolName: "create_task", argumentsJSON: "{}", needsConfirmation: false).userFacingDescription, "Flowts: create task")
    }
}
