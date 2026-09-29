import Foundation

/// Mac settings Macky can change directly, without the model.
public enum SystemCommand: Equatable, Sendable {
    case setVolume(percent: Int)
    case volumeUp
    case volumeDown
    case mute
    case unmute
    case brightnessUp
    case brightnessDown
    case darkMode(enabled: Bool?)   // nil = toggle
    case lockScreen
    case sleepDisplay

    public var userFacingDescription: String {
        switch self {
        case .setVolume(let percent): return "Volum la \(percent)%"
        case .volumeUp: return "Volum mai tare"
        case .volumeDown: return "Volum mai încet"
        case .mute: return "Sunet oprit"
        case .unmute: return "Sunet pornit"
        case .brightnessUp: return "Luminozitate mai mare"
        case .brightnessDown: return "Luminozitate mai mică"
        case .darkMode(let enabled):
            switch enabled {
            case .some(true): return "Dark mode pornit"
            case .some(false): return "Dark mode oprit"
            case .none: return "Dark mode comutat"
            }
        case .lockScreen: return "Ecran blocat"
        case .sleepDisplay: return "Ecran stins"
        }
    }

    /// Parses the model's `system_control` tool call.
    public init?(toolArgumentsJSON: String) {
        guard let data = toolArgumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = (arguments["action"] as? String)?.lowercased() else { return nil }
        switch action {
        case "set_volume":
            guard let percent = OpenRouterStreamDecoder.integerValue(arguments["value"]) else { return nil }
            self = .setVolume(percent: min(max(percent, 0), 100))
        case "volume_up": self = .volumeUp
        case "volume_down": self = .volumeDown
        case "mute": self = .mute
        case "unmute": self = .unmute
        case "brightness_up": self = .brightnessUp
        case "brightness_down": self = .brightnessDown
        case "dark_mode_on": self = .darkMode(enabled: true)
        case "dark_mode_off": self = .darkMode(enabled: false)
        case "dark_mode_toggle": self = .darkMode(enabled: nil)
        case "lock_screen": self = .lockScreen
        case "sleep_display": self = .sleepDisplay
        default: return nil
        }
    }
}

/// Recognizes short spoken system commands in Romanian and English.
public enum SystemCommandMatcher {
    public static func match(_ transcript: String) -> SystemCommand? {
        let text = SpotifyCommandMatcher.fold(QuickCommandMatcher.normalize(transcript))
        guard !text.isEmpty, text.split(separator: " ").count <= 8 else { return nil }

        if text.contains("volum") || text.contains("volume") || text.contains("sunet") || text.contains("sound") {
            if let percent = firstNumber(in: text) { return .setVolume(percent: min(max(percent, 0), 100)) }
            if containsAny(text, ["mai tare", "mareste", "creste", "up", "louder"]) { return .volumeUp }
            if containsAny(text, ["mai incet", "scade", "micsoreaza", "down", "quieter"]) { return .volumeDown }
            if containsAny(text, ["opreste", "fara", "mute", "taie", "off"]) { return .mute }
            if containsAny(text, ["porneste", "da drumul", "unmute", "on"]) { return .unmute }
        }
        // "da mai tare", "pune muzica mai tare": louder/quieter at the end is about volume.
        if text == "mai tare" || text == "louder" || text.hasSuffix(" mai tare") || text.hasSuffix(" louder") { return .volumeUp }
        if text == "mai incet" || text == "quieter" || text.hasSuffix(" mai incet") || text.hasSuffix(" quieter") { return .volumeDown }
        if ["mute", "fara sunet", "taci", "liniste"].contains(text) { return .mute }
        if ["unmute"].contains(text) { return .unmute }

        if text.contains("luminozitat") || text.contains("brightness") || text.contains("ecranul mai") {
            if containsAny(text, ["mai mare", "mai luminos", "creste", "mareste", "up", "higher", "brighter"]) { return .brightnessUp }
            if containsAny(text, ["mai mica", "mai intunecat", "scade", "micsoreaza", "down", "lower", "dimmer"]) { return .brightnessDown }
        }

        if text.contains("dark mode") || text.contains("modul intunecat") || text.contains("tema intunecata") || text.contains("mod intunecat") {
            if containsAny(text, ["opreste", "dezactiveaza", "scoate", "off", "disable", "turn off"]) { return .darkMode(enabled: false) }
            if containsAny(text, ["porneste", "activeaza", "pune", "on", "enable", "turn on"]) { return .darkMode(enabled: true) }
            return .darkMode(enabled: nil)
        }
        if text.contains("light mode") || text.contains("modul luminos") || text.contains("tema luminoasa") {
            return .darkMode(enabled: false)
        }

        if containsAny(text, ["blocheaza ecranul", "blocheaza laptopul", "blocheaza mac", "lock screen", "lock the screen", "lock my mac"]) {
            return .lockScreen
        }
        if containsAny(text, ["stinge ecranul", "opreste ecranul", "turn off the screen", "sleep display"]) {
            return .sleepDisplay
        }
        return nil
    }

    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { phrase in
            // Whole words only, so "on" does not match inside "sunet on" words like "second".
            text == phrase || text.hasPrefix(phrase + " ") || text.hasSuffix(" " + phrase) || text.contains(" " + phrase + " ")
        }
    }

    private static func firstNumber(in text: String) -> Int? {
        guard let range = text.range(of: #"\d{1,3}"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }
}

/// Window layouts for `arrange_window`.
public enum WindowLayout: String, Equatable, Sendable {
    case leftHalf = "left"
    case rightHalf = "right"
    case topHalf = "top"
    case bottomHalf = "bottom"
    case maximize = "full"
    case center = "center"

    public var displayName: String {
        switch self {
        case .leftHalf: return "în stânga"
        case .rightHalf: return "în dreapta"
        case .topHalf: return "sus"
        case .bottomHalf: return "jos"
        case .maximize: return "pe tot ecranul"
        case .center: return "în centru"
        }
    }

    /// The window frame inside a screen's visible area (AppKit coordinates, y up).
    public func frame(in visibleFrame: CGRect) -> CGRect {
        let halfWidth = visibleFrame.width / 2
        let halfHeight = visibleFrame.height / 2
        switch self {
        case .leftHalf: return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
        case .rightHalf: return CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
        case .topHalf: return CGRect(x: visibleFrame.minX, y: visibleFrame.minY + halfHeight, width: visibleFrame.width, height: halfHeight)
        case .bottomHalf: return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: halfHeight)
        case .maximize: return visibleFrame
        case .center:
            let width = visibleFrame.width * 0.6
            let height = visibleFrame.height * 0.7
            return CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2, width: width, height: height)
        }
    }
}
