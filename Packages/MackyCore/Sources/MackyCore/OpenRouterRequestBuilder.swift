import Foundation

/// Builds the JSON body for OpenRouter's OpenAI-compatible `/chat/completions` endpoint.
public enum OpenRouterRequestBuilder {
    public static let pointAtToolName = "point_at"

    public static func makeChatCompletionBody(
        modelIdentifier: String,
        messages: [ChatMessage],
        includePointingTool: Bool,
        coordinateConvention: CoordinateConvention,
        maximumResponseTokens: Int = 700
    ) throws -> Data {
        var body: [String: Any] = [
            "model": modelIdentifier,
            "stream": true,
            "max_tokens": maximumResponseTokens,
            "messages": messages.map(encodeMessage),
            // Asks OpenRouter to append token counts and the credit cost to the final stream chunk.
            "usage": ["include": true]
        ]
        if includePointingTool {
            body["tools"] = [pointAtToolDefinition(coordinateConvention: coordinateConvention)]
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func pointAtToolDefinition(coordinateConvention: CoordinateConvention) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": pointAtToolName,
                "description": "Moves Macky's on-screen cursor to a UI element so the user can see where to look or click. "
                    + "Call it once per element, in the order the user should use them. "
                    + coordinateConvention.toolCoordinateDescription,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "screen": ["type": "integer", "description": "Screenshot number the element is on (1 = first screenshot)."],
                        "x": ["type": "number", "description": "Horizontal position of the element's center."],
                        "y": ["type": "number", "description": "Vertical position of the element's center."],
                        "label": ["type": "string", "description": "Very short name of the element, in the user's language (e.g. 'Export')."]
                    ],
                    "required": ["screen", "x", "y", "label"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    private static func encodeMessage(_ message: ChatMessage) -> [String: Any] {
        // Text-only messages use the plain string form, which every model on OpenRouter accepts.
        if !message.containsImage {
            return ["role": message.role.rawValue, "content": message.plainText]
        }
        let contentParts: [[String: Any]] = message.parts.map { part in
            switch part {
            case .text(let text):
                return ["type": "text", "text": text]
            case .jpegImage(let base64EncodedData):
                return ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64EncodedData)"]]
            }
        }
        return ["role": message.role.rawValue, "content": contentParts]
    }
}
