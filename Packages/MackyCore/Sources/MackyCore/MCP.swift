import Foundation

/// Client side of the Model Context Protocol (Streamable HTTP transport): Macky connects to MCP servers,
/// such as the user's own apps, lists their tools and lets the model call them.
public enum MCPProtocol {
    public static let protocolVersion = "2025-06-18"

    public static func initializeRequest(identifier: Int) -> Data {
        encode([
            "jsonrpc": "2.0", "id": identifier, "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Macky", "version": "1.0"]
            ] as [String: Any]
        ])
    }

    public static func initializedNotification() -> Data {
        encode(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    public static func listToolsRequest(identifier: Int, cursor: String?) -> Data {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }
        return encode(["jsonrpc": "2.0", "id": identifier, "method": "tools/list", "params": params])
    }

    public static func callToolRequest(identifier: Int, name: String, argumentsJSON: String) -> Data {
        let arguments = argumentsJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return encode(["jsonrpc": "2.0", "id": identifier, "method": "tools/call", "params": ["name": name, "arguments": arguments] as [String: Any]])
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    public struct RPCError: Error, Equatable, LocalizedError {
        public var message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// The JSON-RPC response with this id, from a plain JSON body or a server-sent event stream.
    public static func response(withIdentifier identifier: Int, in body: Data, contentType: String?) throws -> [String: Any] {
        var candidates: [[String: Any]] = []
        if (contentType ?? "").lowercased().contains("text/event-stream") {
            let text = String(decoding: body, as: UTF8.self)
            var eventData = ""
            func flush() {
                if !eventData.isEmpty, let data = eventData.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    candidates += (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
                }
                eventData = ""
            }
            // Split on scalars: "\r\n" is a single Character, so splitting a String on "\n" would miss it.
            for rawLine in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
                var scalars = String.UnicodeScalarView(rawLine)
                if scalars.last == "\r" { scalars.removeLast() }
                let line = String(scalars)
                if line.isEmpty {
                    flush()
                } else if line.hasPrefix("data:") {
                    let value = line.dropFirst(5).drop(while: { $0 == " " })
                    eventData += eventData.isEmpty ? String(value) : "\n" + value
                }
            }
            flush()
        } else if let object = try? JSONSerialization.jsonObject(with: body) {
            candidates = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
        }
        guard let message = candidates.first(where: { OpenRouterStreamDecoder.integerValue($0["id"]) == identifier }) else {
            throw RPCError(message: "The server sent no answer to the request.")
        }
        if let error = message["error"] as? [String: Any] {
            throw RPCError(message: (error["message"] as? String) ?? "Server error.")
        }
        return (message["result"] as? [String: Any]) ?? [:]
    }

    /// Reads a tools/list result; returns the tools and the cursor of the next page.
    public static func parseTools(fromResult result: [String: Any]) -> (tools: [MCPToolDescriptor], nextCursor: String?) {
        let tools = ((result["tools"] as? [[String: Any]]) ?? []).compactMap { entry -> MCPToolDescriptor? in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let annotations = entry["annotations"] as? [String: Any] ?? [:]
            let schema = (entry["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
            let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return MCPToolDescriptor(
                name: name,
                title: (entry["title"] as? String) ?? (annotations["title"] as? String),
                description: (entry["description"] as? String) ?? "",
                inputSchemaJSON: schemaJSON,
                isReadOnly: (annotations["readOnlyHint"] as? Bool) ?? false,
                isDestructive: (annotations["destructiveHint"] as? Bool) ?? false
            )
        }
        let cursor = (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (tools, cursor)
    }

    /// Text of a tools/call result (text items, and structured content when there is no text).
    public static func toolResultText(fromResult result: [String: Any], maximumCharacters: Int = 12_000) -> (text: String, isError: Bool) {
        var parts: [String] = []
        for item in (result["content"] as? [[String: Any]]) ?? [] {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "resource":
                if let resource = item["resource"] as? [String: Any], let text = resource["text"] as? String { parts.append(text) }
            case "image":
                parts.append("[image]")
            default:
                break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        var text = parts.joined(separator: "\n")
        if text.isEmpty { text = "Done (no output)." }
        if text.count > maximumCharacters { text = String(text.prefix(maximumCharacters)) + "\n[…truncated]" }
        return (text, (result["isError"] as? Bool) ?? false)
    }
}

public struct MCPToolDescriptor: Equatable, Sendable {
    public var name: String
    public var title: String?
    public var description: String
    public var inputSchemaJSON: String
    public var isReadOnly: Bool
    public var isDestructive: Bool

    public init(name: String, title: String?, description: String, inputSchemaJSON: String, isReadOnly: Bool, isDestructive: Bool) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.isReadOnly = isReadOnly
        self.isDestructive = isDestructive
    }

    /// Asks before running: tools marked destructive, or whose name says they delete.
    public var needsConfirmation: Bool {
        guard !isReadOnly else { return false }
        if isDestructive { return true }
        let folded = name.lowercased()
        return ["delete", "remove", "destroy", "sterge", "archive"].contains { folded.contains($0) }
    }
}

/// How MCP tools are named and described to the model: "mcp_<server>__<tool>", within the 64-character limit.
public enum MCPToolNaming {
    public static let prefix = "mcp_"

    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" }
        let collapsed = String(mapped).replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    public static func modelToolName(serverName: String, toolName: String) -> String {
        let name = prefix + String(slug(serverName).prefix(16)) + "__" + slug(toolName)
        return String(name.prefix(64))
    }

    /// The tool definition sent to the model, with the server's own JSON schema.
    public static func toolDefinition(serverName: String, tool: MCPToolDescriptor) -> [String: Any] {
        var schema = (tool.inputSchemaJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        schema["type"] = "object"
        schema.removeValue(forKey: "$schema")
        // Google's models reject object schemas without properties.
        if ((schema["properties"] as? [String: Any]) ?? [:]).isEmpty {
            schema["properties"] = ["note": ["type": "string", "description": "Optional; leave empty."]]
        }
        let label = tool.title.map { "\($0). " } ?? ""
        return [
            "type": "function",
            "function": [
                "name": modelToolName(serverName: serverName, toolName: tool.name),
                "description": "[\(serverName)] " + label + String(tool.description.prefix(900)),
                "parameters": schema
            ] as [String: Any]
        ]
    }
}
