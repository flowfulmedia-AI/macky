import Foundation

public enum ClickKind: String, Equatable, Sendable {
    case left
    case double
    case right

    public var displayName: String {
        switch self {
        case .left: return "Apasă"
        case .double: return "Dublu-click"
        case .right: return "Click dreapta"
        }
    }
}

/// Something the model asked Macky to do on the computer.
public enum ScreenAction: Equatable, Sendable {
    case click(target: PointingInstruction, kind: ClickKind)
    case typeText(text: String, pressEnterAfterwards: Bool)
    case pressKeys(KeyCombination)
    case openApplication(name: String)
    case openURL(String)
    case runAppleScript(String)
    /// Presses an element found by name in the accessibility tree; nil application means the app in front.
    case clickElement(label: String, applicationName: String?)
    case spotify(SpotifyCommand)
    case system(SystemCommand)
    case createEvent(CalendarEventRequest)
    case listEvents(from: Date, to: Date)
    case createReminder(title: String, dueDate: Date?, notes: String?)
    case listReminders(limit: Int)
    case createNote(title: String, body: String)
    case arrangeWindow(applicationName: String?, layout: WindowLayout)
    case startBackgroundTask(goal: String)
    /// Plays, pauses or skips in whatever app is playing media (the keyboard's media keys).
    case mediaKey(MediaKey)
    case remember(kind: MemoryKind, subject: String, content: String)
    case forget(query: String)
    case recall(query: String)
    case replaceSelection(text: String)
    case useSkill(name: String)
    case webSearch(query: String)
    case fetchURL(String)
    case searchFiles(query: String, kind: String)
    case readFile(path: String)
    case openFile(path: String)
    case searchGmail(query: String, maximumResults: Int)
    case readEmail(identifier: String)
    case searchDrive(query: String)
    case readDriveFile(identifier: String)

    /// Parses an action tool call. Returns nil for `point_at` or malformed arguments.
    public init?(toolCall: ChatToolCall) {
        guard let tool = MackyTool(rawValue: toolCall.name), tool.isAction || tool.isMemoryTool || tool.isInformationTool else { return nil }
        let arguments = (toolCall.argumentsJSON.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        switch tool {
        case .click:
            guard let target = PointingInstruction(toolArgumentsJSON: toolCall.argumentsJSON) else { return nil }
            let kind = ClickKind(rawValue: (arguments["button"] as? String)?.lowercased() ?? "left") ?? .left
            self = .click(target: target, kind: kind)
        case .typeText:
            guard let text = arguments["text"] as? String, !text.isEmpty else { return nil }
            let pressEnter = (arguments["press_enter"] as? Bool) ?? ((arguments["press_enter"] as? String) == "true")
            self = .typeText(text: text, pressEnterAfterwards: pressEnter)
        case .pressKeys:
            guard let keys = arguments["keys"] as? String, let combination = KeyCombination(parsing: keys) else { return nil }
            self = .pressKeys(combination)
        case .openApplication:
            guard let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            self = .openApplication(name: name)
        case .openURL:
            guard let url = (arguments["url"] as? String)?.trimmingCharacters(in: .whitespaces), url.contains(":") else { return nil }
            self = .openURL(url)
        case .runAppleScript:
            guard let script = arguments["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .runAppleScript(script)
        case .clickElement:
            guard let label = (arguments["label"] as? String)?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
            let applicationName = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespaces)
            self = .clickElement(label: label, applicationName: (applicationName?.isEmpty ?? true) ? nil : applicationName)
        case .spotify:
            guard let command = SpotifyCommand(toolArgumentsJSON: toolCall.argumentsJSON) else { return nil }
            self = .spotify(command)
        case .systemControl:
            guard let command = SystemCommand(toolArgumentsJSON: toolCall.argumentsJSON) else { return nil }
            self = .system(command)
        case .createEvent:
            guard let title = Self.nonEmptyString(arguments["title"]),
                  let startDate = FlexibleDateParser.date(from: arguments["start"] as? String) else { return nil }
            let isAllDay = (arguments["all_day"] as? Bool) ?? false
            let endDate = FlexibleDateParser.date(from: arguments["end"] as? String)
                ?? startDate.addingTimeInterval(isAllDay ? 24 * 3600 : 3600)
            self = .createEvent(CalendarEventRequest(
                title: title, startDate: startDate, endDate: max(endDate, startDate.addingTimeInterval(60)), isAllDay: isAllDay,
                location: Self.nonEmptyString(arguments["location"]), notes: Self.nonEmptyString(arguments["notes"])
            ))
        case .listEvents:
            guard let fromDate = FlexibleDateParser.date(from: arguments["from"] as? String),
                  let toDate = FlexibleDateParser.date(from: arguments["to"] as? String) else { return nil }
            self = .listEvents(from: fromDate, to: max(toDate, fromDate))
        case .createReminder:
            guard let title = Self.nonEmptyString(arguments["title"]) else { return nil }
            self = .createReminder(title: title, dueDate: FlexibleDateParser.date(from: arguments["due"] as? String), notes: Self.nonEmptyString(arguments["notes"]))
        case .listReminders:
            self = .listReminders(limit: min(max(OpenRouterStreamDecoder.integerValue(arguments["limit"]) ?? 20, 1), 100))
        case .createNote:
            guard let title = Self.nonEmptyString(arguments["title"]) else { return nil }
            self = .createNote(title: title, body: (arguments["body"] as? String) ?? "")
        case .arrangeWindow:
            guard let layout = WindowLayout(rawValue: ((arguments["layout"] as? String) ?? "").lowercased()) else { return nil }
            self = .arrangeWindow(applicationName: Self.nonEmptyString(arguments["app"]), layout: layout)
        case .startBackgroundTask:
            guard let goal = Self.nonEmptyString(arguments["goal"]) else { return nil }
            self = .startBackgroundTask(goal: goal)
        case .remember:
            guard let content = Self.nonEmptyString(arguments["content"]) else { return nil }
            let kind = MemoryKind(rawValue: ((arguments["kind"] as? String) ?? "").lowercased()) ?? .fact
            self = .remember(kind: kind, subject: Self.nonEmptyString(arguments["subject"]) ?? String(content.prefix(40)), content: String(content.prefix(500)))
        case .forget:
            guard let query = Self.nonEmptyString(arguments["query"]) else { return nil }
            self = .forget(query: query)
        case .recall:
            guard let query = Self.nonEmptyString(arguments["query"]) else { return nil }
            self = .recall(query: query)
        case .replaceSelection:
            guard let text = arguments["text"] as? String, !text.isEmpty else { return nil }
            self = .replaceSelection(text: text)
        case .useSkill:
            guard let name = Self.nonEmptyString(arguments["name"]) else { return nil }
            self = .useSkill(name: name)
        case .webSearch:
            guard let query = Self.nonEmptyString(arguments["query"]) else { return nil }
            self = .webSearch(query: query)
        case .fetchURL:
            guard let url = Self.nonEmptyString(arguments["url"]) else { return nil }
            self = .fetchURL(url)
        case .searchFiles:
            guard let query = Self.nonEmptyString(arguments["query"]) else { return nil }
            self = .searchFiles(query: query, kind: Self.nonEmptyString(arguments["kind"])?.lowercased() ?? "any")
        case .readFile:
            guard let path = Self.nonEmptyString(arguments["path"]) else { return nil }
            self = .readFile(path: path)
        case .openFile:
            guard let path = Self.nonEmptyString(arguments["path"]) else { return nil }
            self = .openFile(path: path)
        case .searchGmail:
            guard let query = Self.nonEmptyString(arguments["query"]) else { return nil }
            self = .searchGmail(query: query, maximumResults: min(max(OpenRouterStreamDecoder.integerValue(arguments["max_results"]) ?? 10, 1), 25))
        case .readEmail:
            guard let identifier = Self.nonEmptyString(arguments["id"]) else { return nil }
            self = .readEmail(identifier: identifier)
        case .searchDrive:
            guard let query = Self.nonEmptyString(arguments["query"]) else { return nil }
            self = .searchDrive(query: query)
        case .readDriveFile:
            guard let identifier = Self.nonEmptyString(arguments["id"]) else { return nil }
            self = .readDriveFile(identifier: identifier)
        case .pointAt, .taskDone, .saveFile, .finishTask:
            return nil
        }
    }

    /// Short description for the confirmation card and the model's history, in Romanian.
    public var userFacingDescription: String {
        switch self {
        case .click(let target, let kind):
            return target.label.isEmpty ? kind.displayName : "\(kind.displayName) pe „\(target.label)”"
        case .typeText(let text, let pressEnterAfterwards):
            let shortenedText = text.count > 60 ? String(text.prefix(60)) + "…" : text
            return "Scrie „\(shortenedText)”" + (pressEnterAfterwards ? " și apasă Enter" : "")
        case .pressKeys(let combination):
            return "Apasă \(combination.displayName)"
        case .openApplication(let name):
            return "Deschide \(name)"
        case .openURL(let url):
            let shortenedURL = url.count > 70 ? String(url.prefix(70)) + "…" : url
            return "Deschide \(shortenedURL)"
        case .runAppleScript(let script):
            let targetApplication = script.range(of: #"application "([^"]+)""#, options: .regularExpression)
                .map { String(script[$0]).replacingOccurrences(of: "application ", with: "").replacingOccurrences(of: "\"", with: "") }
            return targetApplication.map { "Controlează \($0) direct" } ?? "Rulează o comandă AppleScript"
        case .clickElement(let label, let applicationName):
            return applicationName.map { "Apasă „\(label)” în \($0)" } ?? "Apasă „\(label)”"
        case .mediaKey(let mediaKey):
            return mediaKey.displayName
        case .spotify(let command):
            return command.userFacingDescription
        case .system(let command):
            return command.userFacingDescription
        case .createEvent(let request):
            return "Adaugă în calendar „\(request.title)” (\(FlexibleDateParser.shortDescription(of: request.startDate)))"
        case .listEvents:
            return "Citește calendarul"
        case .createReminder(let title, let dueDate, _):
            return "Reminder „\(title)”" + (dueDate.map { " (\(FlexibleDateParser.shortDescription(of: $0)))" } ?? "")
        case .listReminders:
            return "Citește reminderele"
        case .createNote(let title, _):
            return "Notiță nouă „\(title)”"
        case .arrangeWindow(let applicationName, let layout):
            return "Mută \(applicationName ?? "fereastra") \(layout.displayName)"
        case .startBackgroundTask(let goal):
            return "Agent în fundal: \(goal.count > 60 ? String(goal.prefix(60)) + "…" : goal)"
        case .remember(_, let subject, _):
            return "Ține minte: \(subject)"
        case .forget(let query):
            return "Uită: \(query)"
        case .recall(let query):
            return "Caută în memorie: \(query)"
        case .replaceSelection(let text):
            return "Înlocuiește textul selectat cu „\(text.count > 60 ? String(text.prefix(60)) + "…" : text)”"
        case .useSkill(let name):
            return "Folosește skill-ul \(name)"
        case .webSearch(let query):
            return "Caută pe web: \(query)"
        case .fetchURL(let url):
            return "Citește \(url.count > 60 ? String(url.prefix(60)) + "…" : url)"
        case .searchFiles(let query, _):
            return "Caută fișiere: \(query)"
        case .readFile(let path):
            return "Citește \((path as NSString).lastPathComponent)"
        case .openFile(let path):
            return "Deschide \((path as NSString).lastPathComponent)"
        case .searchGmail(let query, _):
            return "Caută în Gmail: \(query)"
        case .readEmail:
            return "Citește un email"
        case .searchDrive(let query):
            return "Caută în Google Drive: \(query)"
        case .readDriveFile:
            return "Citește un fișier din Drive"
        }
    }

    /// Actions that only read, never change anything, so they need no confirmation.
    public var isReadOnly: Bool {
        switch self {
        case .listEvents, .listReminders, .recall, .useSkill, .webSearch, .fetchURL,
             .searchFiles, .readFile, .searchGmail, .readEmail, .searchDrive, .readDriveFile: return true
        default: return false
        }
    }

    /// Memory tools work on Macky's own data: no screen, no Accessibility, no confirmation.
    public var isMemoryOperation: Bool {
        switch self {
        case .remember, .forget, .recall: return true
        default: return false
        }
    }

    /// Works without the screen: memory, web and skills. No new screenshot is needed after these.
    public var needsNoScreen: Bool {
        switch self {
        case .remember, .forget, .recall, .useSkill, .webSearch, .fetchURL,
             .searchFiles, .readFile, .searchGmail, .readEmail, .searchDrive, .readDriveFile: return true
        default: return false
        }
    }

    /// Returns information the model has to read before it can answer.
    public var returnsInformation: Bool {
        switch self {
        case .recall, .useSkill, .webSearch, .fetchURL, .listEvents, .listReminders,
             .searchFiles, .readFile, .searchGmail, .readEmail, .searchDrive, .readDriveFile: return true
        default: return false
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// A key plus modifiers, e.g. cmd+shift+s, as macOS virtual key codes.
public struct KeyCombination: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierKeys
    public var displayName: String

    public init(keyCode: UInt16, modifiers: ModifierKeys, displayName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayName = displayName
    }

    /// Accepts forms like "cmd+s", "Command+Shift+N", "⌘S", "enter", "down".
    public init?(parsing text: String) {
        var normalizedText = text.lowercased().trimmingCharacters(in: .whitespaces)
        for (symbol, name) in [("⌘", "cmd+"), ("⇧", "shift+"), ("⌥", "option+"), ("⌃", "ctrl+")] {
            normalizedText = normalizedText.replacingOccurrences(of: symbol, with: name)
        }
        let tokens = normalizedText
            .split(whereSeparator: { $0 == "+" || $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let keyToken = tokens.last else { return nil }

        var modifiers: ModifierKeys = []
        for modifierToken in tokens.dropLast() {
            switch modifierToken {
            case "cmd", "command", "meta", "super": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "option", "opt", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: return nil
            }
        }
        guard let keyCode = Self.virtualKeyCodes[keyToken] else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, displayName: modifiers.symbols + keyToken.uppercased())
    }

    /// macOS virtual key codes (ANSI layout).
    static let virtualKeyCodes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
            "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111
        ]
        codes["arrowleft"] = 123
        codes["arrowright"] = 124
        codes["arrowdown"] = 125
        codes["arrowup"] = 126
        return codes
    }()
}

/// A shape the user drew on screen while asking, summarized for the model.
public struct UserScreenMarking: Equatable, Sendable {
    public var screenNumber: Int
    /// Bounding box of the drawing in the model's coordinate convention.
    public var minimumX: Double
    public var minimumY: Double
    public var maximumX: Double
    public var maximumY: Double

    public init(screenNumber: Int, minimumX: Double, minimumY: Double, maximumX: Double, maximumY: Double) {
        self.screenNumber = screenNumber
        self.minimumX = minimumX
        self.minimumY = minimumY
        self.maximumX = maximumX
        self.maximumY = maximumY
    }
}
