import Foundation

/// The tools Macky can offer the model.
public enum MackyTool: String, CaseIterable, Sendable {
    case pointAt = "point_at"
    case click = "click"
    case typeText = "type_text"
    case pressKeys = "press_keys"
    case openApplication = "open_app"
    case openURL = "open_url"
    case runAppleScript = "run_applescript"
    case clickElement = "click_element"
    case spotify = "spotify"
    /// Not an action: the model calls it next to its last actions to say no check is needed.
    case taskDone = "task_done"

    /// Tools that change something on the computer (as opposed to only showing).
    public static let actionTools: [MackyTool] = [.spotify, .clickElement, .click, .typeText, .pressKeys, .openApplication, .openURL, .runAppleScript]
    /// Everything offered when Macky may act.
    public static let actingTools: [MackyTool] = actionTools + [.taskDone]

    public var isAction: Bool { Self.actionTools.contains(self) }
}

/// Builds the JSON body for OpenRouter's OpenAI-compatible `/chat/completions` endpoint.
public enum OpenRouterRequestBuilder {
    public static let pointAtToolName = MackyTool.pointAt.rawValue

    public static func makeChatCompletionBody(
        modelIdentifier: String,
        messages: [ChatMessage],
        tools: [MackyTool],
        coordinateConvention: CoordinateConvention,
        disableReasoning: Bool = false,
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
        if disableReasoning {
            // "Thinking" before answering can add several seconds; Macky's tasks rarely need it.
            body["reasoning"] = ["enabled": false]
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { toolDefinition(for: $0, coordinateConvention: coordinateConvention) }
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func toolDefinition(for tool: MackyTool, coordinateConvention: CoordinateConvention) -> [String: Any] {
        let description: String
        let properties: [String: Any]
        let required: [String]
        let screenPositionProperties: [String: Any] = [
            "screen": ["type": "integer", "description": "Screenshot number the element is on (1 = first screenshot)."],
            "x": ["type": "number", "description": "Horizontal position of the element's center."],
            "y": ["type": "number", "description": "Vertical position of the element's center."],
            "label": ["type": "string", "description": "Very short name of the element, in the user's language (e.g. 'Export')."]
        ]

        switch tool {
        case .pointAt:
            description = "Moves Macky's on-screen cursor to a UI element so the user can see where to look or click. "
                + "Call it once per element, in the order the user should use them. "
                + coordinateConvention.toolCoordinateDescription
            properties = screenPositionProperties
            required = ["screen", "x", "y", "label"]
        case .click:
            description = "Clicks a UI element on the user's screen with the mouse. Use only when the user asked you to do something for them. "
                + coordinateConvention.toolCoordinateDescription
            var clickProperties = screenPositionProperties
            clickProperties["button"] = ["type": "string", "enum": ["left", "double", "right"], "description": "left = normal click (default), double = double-click, right = right-click."]
            properties = clickProperties
            required = ["screen", "x", "y", "label"]
        case .typeText:
            description = "Types text into the currently focused text field (click the field first). Use only when the user asked you to do something for them."
            properties = [
                "text": ["type": "string", "description": "The exact text to type."],
                "press_enter": ["type": "boolean", "description": "Press Enter after typing (e.g. to submit a search)."]
            ]
            required = ["text"]
        case .pressKeys:
            description = "Presses a key or keyboard shortcut, e.g. 'enter', 'escape', 'tab', 'cmd+s', 'cmd+shift+n', 'down'. Use only when the user asked you to do something for them."
            properties = [
                "keys": ["type": "string", "description": "Keys joined with '+', modifiers first: cmd, shift, option, ctrl."]
            ]
            required = ["keys"]
        case .openApplication:
            description = "Opens (or brings to the front) a Mac application by name, instantly. Much faster than clicking through the Dock or Spotlight."
            properties = [
                "name": ["type": "string", "description": "Application name as in the Applications folder, e.g. 'Spotify', 'Safari', 'System Settings'."]
            ]
            required = ["name"]
        case .openURL:
            description = "Opens a URL instantly: web pages (https://...) or app links, e.g. 'spotify:search:bohemian rhapsody', "
                + "'https://www.youtube.com/results?search_query=cats', 'mailto:someone@example.com'. The fastest way to search or navigate."
            properties = [
                "url": ["type": "string", "description": "The full URL, with any spaces or special characters in search terms percent-encoded or as plain text."]
            ]
            required = ["url"]
        case .runAppleScript:
            description = "Runs an AppleScript to control an app directly, in one step, without clicking. The fastest way to control scriptable apps "
                + "(Spotify, Music, Safari, Finder, Mail, Notes, Calendar, System Events). Examples: "
                + "tell application \"Spotify\" to play track \"spotify:track:4uLU6hMCjMI75M1A2tKUQC\"; "
                + "tell application \"Spotify\" to next track; tell application \"Music\" to playpause; "
                + "tell application \"Safari\" to make new document with properties {URL:\"https://example.com\"}. "
                + "Returns the script's result or its error message."
            properties = [
                "script": ["type": "string", "description": "The complete AppleScript source."]
            ]
            required = ["script"]
        case .clickElement:
            description = "Presses a button, link, tab or menu item by its visible name or accessibility label, found directly in the app, "
                + "without needing screen coordinates. Waits up to 4 seconds for it to appear, so it can follow open_app or open_url "
                + "in the same response. Preferred over click whenever you know the element's name. If nothing matches, the result lists "
                + "the names that are available."
            properties = [
                "label": ["type": "string", "description": "Name of the element, e.g. 'Play', 'Liked Songs', 'Search', 'Salvează'."],
                "app": ["type": "string", "description": "Application to look in, e.g. 'Spotify'. Omit for the app in front."]
            ]
            required = ["label"]
        case .spotify:
            description = "Controls the Spotify app directly and reliably (no clicking): plays a song, album, artist or playlist by name, "
                + "plays the user's Liked Songs, pauses, resumes or skips. It checks what is actually playing and reports it. "
                + "ALWAYS use this for anything about Spotify or playing music."
            properties = [
                "action": ["type": "string", "enum": ["play", "play_liked_songs", "pause", "resume", "next", "previous"]],
                "query": ["type": "string", "description": "For action=play: what to search, e.g. 'Numb Linkin Park'."],
                "kind": ["type": "string", "enum": ["track", "album", "artist", "playlist"], "description": "For action=play; default track."]
            ]
            required = ["action"]
        case .taskDone:
            description = "Call this in the same response as your final actions when they certainly complete the task, "
                + "so no new screenshot is needed. Do not call it if you need to check the result."
            // Google's models reject tools whose parameter object has no properties, so there is one optional field.
            properties = [
                "note": ["type": "string", "description": "Optional short note about what was done."]
            ]
            required = []
        }

        return [
            "type": "function",
            "function": [
                "name": tool.rawValue,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    private static func encodeMessage(_ message: ChatMessage) -> [String: Any] {
        var encodedMessage: [String: Any] = ["role": message.role.rawValue]

        // Text-only messages use the plain string form, which every model on OpenRouter accepts.
        if !message.containsImage {
            let text = message.plainText
            // An assistant message that only called tools has no text; OpenAI-style APIs expect null then.
            encodedMessage["content"] = (text.isEmpty && !message.toolCalls.isEmpty) ? NSNull() : text
        } else {
            encodedMessage["content"] = message.parts.map { part -> [String: Any] in
                switch part {
                case .text(let text):
                    return ["type": "text", "text": text]
                case .jpegImage(let base64EncodedData):
                    return ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64EncodedData)"]]
                }
            }
        }

        if !message.toolCalls.isEmpty {
            encodedMessage["tool_calls"] = message.toolCalls.map { toolCall -> [String: Any] in
                [
                    "id": toolCall.identifier,
                    "type": "function",
                    "function": ["name": toolCall.name, "arguments": toolCall.argumentsJSON]
                ]
            }
        }
        if let toolCallIdentifier = message.toolCallIdentifier {
            encodedMessage["tool_call_id"] = toolCallIdentifier
        }
        return encodedMessage
    }
}
