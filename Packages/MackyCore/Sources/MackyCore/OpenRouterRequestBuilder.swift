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
    case systemControl = "system_control"
    case createEvent = "create_event"
    case listEvents = "list_events"
    case createReminder = "create_reminder"
    case listReminders = "list_reminders"
    case createNote = "create_note"
    case arrangeWindow = "arrange_window"
    case startBackgroundTask = "start_background_task"
    /// Not an action: the model calls it next to its last actions to say no check is needed.
    case taskDone = "task_done"
    // Tools of background agent jobs only.
    case webSearch = "web_search"
    case fetchURL = "fetch_url"
    case saveFile = "save_file"
    case finishTask = "finish_task"
    // Long-term memory.
    case remember = "remember"
    case forget = "forget"
    case recall = "recall"
    // Writing assistant and Claude skills.
    case replaceSelection = "replace_selection"
    case useSkill = "use_skill"
    // Files on the Mac, Gmail and Google Drive.
    case searchFiles = "search_files"
    case readFile = "read_file"
    case openFile = "open_file"
    case searchGmail = "search_gmail"
    case readEmail = "read_email"
    case searchDrive = "search_drive"
    case readDriveFile = "read_drive_file"

    /// Tools that change something on the computer (as opposed to only showing).
    public static let actionTools: [MackyTool] = [
        .spotify, .systemControl, .createEvent, .listEvents, .createReminder, .listReminders, .createNote, .arrangeWindow,
        .startBackgroundTask, .replaceSelection, .openFile, .clickElement, .click, .typeText, .pressKeys, .openApplication, .openURL, .runAppleScript
    ]
    /// Everything offered when Macky may act.
    public static let actingTools: [MackyTool] = actionTools + [.taskDone]
    /// Offered to background agent jobs, which never touch the screen.
    public static let backgroundAgentTools: [MackyTool] = [
        .webSearch, .fetchURL, .saveFile, .createNote, .createEvent, .listEvents, .createReminder, .listReminders, .finishTask
    ]

    /// Offered whenever tools are, even when Macky may not act on the computer.
    public static let memoryTools: [MackyTool] = [.remember, .forget, .recall]
    /// Tools that only fetch information (web, skills); offered whenever tools are.
    public static let informationTools: [MackyTool] = [
        .webSearch, .fetchURL, .useSkill, .searchFiles, .readFile, .searchGmail, .readEmail, .searchDrive, .readDriveFile
    ]
    /// Need a connected Google account.
    public static let googleTools: Set<MackyTool> = [.searchGmail, .readEmail, .searchDrive, .readDriveFile]

    public var isAction: Bool { Self.actionTools.contains(self) }
    public var isMemoryTool: Bool { Self.memoryTools.contains(self) }
    public var isInformationTool: Bool { Self.informationTools.contains(self) }
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
        enableWebSearch: Bool = false,
        maximumResponseTokens: Int = 700,
        cacheSystemPrompt: Bool = false,
        extraToolDefinitions: [[String: Any]] = []
    ) throws -> Data {
        var encodedMessages = messages.map(encodeMessage)
        if cacheSystemPrompt, let systemIndex = messages.firstIndex(where: { $0.role == .system }) {
            // Anthropic models only reuse a prompt prefix when it is marked; the system prompt and tools
            // are the same in every request, so later requests pay a fraction for them.
            encodedMessages[systemIndex]["content"] = [[
                "type": "text",
                "text": messages[systemIndex].plainText,
                "cache_control": ["type": "ephemeral"]
            ] as [String: Any]]
        }
        var body: [String: Any] = [
            "model": modelIdentifier,
            "stream": true,
            "max_tokens": maximumResponseTokens,
            "messages": encodedMessages,
            // Asks OpenRouter to append token counts and the credit cost to the final stream chunk.
            "usage": ["include": true]
        ]
        if enableWebSearch {
            // OpenRouter's web plugin searches the web and gives the results to the model (small extra cost per request).
            body["plugins"] = [["id": "web", "max_results": 6]]
        }
        if disableReasoning {
            // "Thinking" before answering can add several seconds; Macky's tasks rarely need it.
            body["reasoning"] = ["enabled": false]
        }
        if !tools.isEmpty || !extraToolDefinitions.isEmpty {
            // Connected apps' (MCP) tools come after Macky's own, so the cached prefix stays the same.
            body["tools"] = tools.map { toolDefinition(for: $0, coordinateConvention: coordinateConvention) } + extraToolDefinitions
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Models that need explicit cache markers (others, like OpenAI and Gemini, cache on their own).
    public static func needsExplicitPromptCaching(modelIdentifier: String) -> Bool {
        modelIdentifier.hasPrefix("anthropic/")
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
        case .systemControl:
            description = "Changes Mac settings instantly: volume, mute, screen brightness, dark mode, lock the screen, turn the display off."
            properties = [
                "action": ["type": "string", "enum": [
                    "set_volume", "volume_up", "volume_down", "mute", "unmute", "brightness_up", "brightness_down",
                    "dark_mode_on", "dark_mode_off", "dark_mode_toggle", "lock_screen", "sleep_display"
                ]],
                "value": ["type": "integer", "description": "For set_volume: 0-100."]
            ]
            required = ["action"]
        case .createEvent:
            description = "Adds an event to the user's Calendar. Use the current date and time given in the message to resolve words like 'mâine' or 'joi'."
            properties = [
                "title": ["type": "string"],
                "start": ["type": "string", "description": "Local start time, ISO 8601, e.g. 2026-10-02T15:00:00."],
                "end": ["type": "string", "description": "Local end time, ISO 8601. Default: one hour after start."],
                "all_day": ["type": "boolean"],
                "location": ["type": "string"],
                "notes": ["type": "string"]
            ]
            required = ["title", "start"]
        case .listEvents:
            description = "Reads the user's Calendar events between two local times (ISO 8601). The result lists them; then tell the user briefly."
            properties = [
                "from": ["type": "string", "description": "e.g. 2026-10-02T00:00:00"],
                "to": ["type": "string", "description": "e.g. 2026-10-02T23:59:59"]
            ]
            required = ["from", "to"]
        case .createReminder:
            description = "Adds a reminder to the user's Reminders app, optionally with a due time that triggers an alert."
            properties = [
                "title": ["type": "string"],
                "due": ["type": "string", "description": "Local due time, ISO 8601. Omit for no due time."],
                "notes": ["type": "string"]
            ]
            required = ["title"]
        case .listReminders:
            description = "Reads the user's open (not completed) reminders."
            properties = [
                "limit": ["type": "integer", "description": "Maximum number to return, default 20."]
            ]
            required = []
        case .createNote:
            description = "Creates a note in the Apple Notes app."
            properties = [
                "title": ["type": "string"],
                "body": ["type": "string", "description": "Plain text; new lines allowed."]
            ]
            required = ["title", "body"]
        case .arrangeWindow:
            description = "Moves and resizes an app's front window: left or right half, top or bottom half, full screen area, or centered. "
                + "Use two calls to put two apps side by side."
            properties = [
                "app": ["type": "string", "description": "Application name, e.g. 'Safari'. Omit for the app in front."],
                "layout": ["type": "string", "enum": ["left", "right", "top", "bottom", "full", "center"]]
            ]
            required = ["layout"]
        case .startBackgroundTask:
            description = "Starts a background agent for long jobs that do not need the screen: web research, comparing products, "
                + "summarizing pages, writing a document or note, planning. It works while the user does other things and reports when done. "
                + "Use it when the user says 'agent', 'în fundal', or asks for research or a long piece of writing."
            properties = [
                "goal": ["type": "string", "description": "The full task in the user's words, with every detail they gave."]
            ]
            required = ["goal"]
        case .replaceSelection:
            description = "Replaces the text the user has selected in the app in front with new text (pasted in place). "
                + "Use it when the user asks you to rewrite, correct, translate, shorten or answer in place of their selected text. "
                + "Also works with no selection to insert text at the cursor."
            properties = [
                "text": ["type": "string", "description": "The complete new text, ready to use, with no comments around it."]
            ]
            required = ["text"]
        case .searchFiles:
            description = "Searches the files on the user's Mac by name and content (Spotlight). Returns paths, newest first. "
                + "Use it when the user asks where a document is, or for a file to read or open."
            properties = [
                "query": ["type": "string", "description": "Words from the file name or content, e.g. 'contract Nordic'."],
                "kind": ["type": "string", "enum": ["any", "document", "pdf", "spreadsheet", "presentation", "image", "folder"], "description": "Default any."]
            ]
            required = ["query"]
        case .readFile:
            description = "Reads the text of a file on the Mac (txt, md, pdf, docx, rtf, csv…), given its full path from search_files."
            properties = ["path": ["type": "string"]]
            required = ["path"]
        case .openFile:
            description = "Opens a file or folder on the Mac in its default app, given its full path."
            properties = ["path": ["type": "string"]]
            required = ["path"]
        case .searchGmail:
            description = "Searches the user's Gmail (read-only) with Gmail search syntax, e.g. 'from:andrei factura', "
                + "'is:unread newer_than:1d', 'subject:ofertă after:2026/09/01'. Returns id, date, sender, subject and snippet for each email."
            properties = [
                "query": ["type": "string"],
                "max_results": ["type": "integer", "description": "Default 10, at most 25."]
            ]
            required = ["query"]
        case .readEmail:
            description = "Reads one Gmail email in full, by the id from search_gmail."
            properties = ["id": ["type": "string"]]
            required = ["id"]
        case .searchDrive:
            description = "Searches the user's Google Drive (read-only) by file name and content. Returns id, name, type, date and link."
            properties = ["query": ["type": "string", "description": "Words to find, e.g. 'contract Nordic'."]]
            required = ["query"]
        case .readDriveFile:
            description = "Reads the text of a Google Drive file (Docs, Sheets as CSV, Slides, PDF, text) by the id from search_drive. "
                + "To show it to the user instead, call open_url with its link."
            properties = ["id": ["type": "string"]]
            required = ["id"]
        case .useSkill:
            description = "Loads one of the user's Claude skills by name and returns its instructions, which you must then follow."
            properties = [
                "name": ["type": "string", "description": "The skill's name exactly as listed."]
            ]
            required = ["name"]
        case .webSearch:
            description = "Searches the web and returns the top results with their URLs and short summaries. "
                + "Use it for current information: news, prices, opening hours, facts you are not sure about."
            properties = ["query": ["type": "string"]]
            required = ["query"]
        case .fetchURL:
            description = "Downloads a web page and returns its readable text (truncated)."
            properties = ["url": ["type": "string"]]
            required = ["url"]
        case .saveFile:
            description = "Saves a text or Markdown file into the user's Macky folder (Documents/Macky) and returns its path."
            properties = [
                "file_name": ["type": "string", "description": "e.g. 'microfoane.md'"],
                "content": ["type": "string"]
            ]
            required = ["file_name", "content"]
        case .finishTask:
            description = "Ends the background task with the final answer for the user."
            properties = [
                "summary": ["type": "string", "description": "2-4 sentences in the user's language: what you found or did."],
                "saved_file_path": ["type": "string", "description": "Path returned by save_file, if any."]
            ]
            required = ["summary"]
        case .remember:
            description = "Saves something to Macky's long-term memory. Use it when the user asks you to remember something, "
                + "or tells you a durable fact worth knowing later: a client or person, where something is (folder, link, account), "
                + "a preference, or a correction of how you should do something. One idea per call, written in Romanian, self-contained."
            properties = [
                "kind": ["type": "string", "enum": MemoryKind.allCases.map(\.rawValue),
                         "description": "person = clients and people, location = where things are, preference, project, lesson = how to do something next time, profile = about the user, fact = other."],
                "subject": ["type": "string", "description": "Short title, usually a name, e.g. 'Raluca Dicu' or 'Facturi 2026'."],
                "content": ["type": "string", "description": "What to remember, under 280 characters."]
            ]
            required = ["kind", "subject", "content"]
        case .forget:
            description = "Deletes memories matching a description, when the user asks you to forget something or says a memory is wrong."
            properties = [
                "query": ["type": "string", "description": "What to forget, e.g. 'adresa lui Andrei'."]
            ]
            required = ["query"]
        case .recall:
            description = "Searches Macky's long-term memory. Use it when the user refers to something they told you before "
                + "(a client, a file location, a preference) and it is not already in 'What you remember'."
            properties = [
                "query": ["type": "string", "description": "What to look for, e.g. 'client Andrei contract'."]
            ]
            required = ["query"]
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
