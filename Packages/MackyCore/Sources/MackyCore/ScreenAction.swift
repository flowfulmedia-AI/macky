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
    /// Plays, pauses or skips in whatever app is playing media (the keyboard's media keys).
    case mediaKey(MediaKey)

    /// Parses an action tool call. Returns nil for `point_at` or malformed arguments.
    public init?(toolCall: ChatToolCall) {
        guard let tool = MackyTool(rawValue: toolCall.name), tool.isAction else { return nil }
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
        case .pointAt, .taskDone:
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
        case .mediaKey(let mediaKey):
            return mediaKey.displayName
        }
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
