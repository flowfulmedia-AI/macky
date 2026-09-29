import Foundation

public struct ModifierKeys: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ModifierKeys(rawValue: 1 << 0)
    public static let option = ModifierKeys(rawValue: 1 << 1)
    public static let shift = ModifierKeys(rawValue: 1 << 2)
    public static let command = ModifierKeys(rawValue: 1 << 3)

    public var symbols: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.shift) { symbols += "⇧" }
        if contains(.command) { symbols += "⌘" }
        return symbols
    }

    public var readableName: String {
        var names: [String] = []
        if contains(.control) { names.append("Control") }
        if contains(.option) { names.append("Option") }
        if contains(.shift) { names.append("Shift") }
        if contains(.command) { names.append("Command") }
        return names.joined(separator: " + ")
    }

    /// Modifier-only combinations offered in Settings.
    public static let selectableCombinations: [ModifierKeys] = [
        [.control, .option],
        [.control, .shift],
        [.option, .shift],
        [.control, .command],
        [.option, .command]
    ]
}

public enum HotkeyAction: String, Sendable {
    case talk
    case dictate
}

public enum HotkeyEvent: Equatable, Sendable {
    case pressed(HotkeyAction)
    case released(HotkeyAction)
    /// The combination turned out to be part of a normal shortcut (another key was pressed),
    /// so whatever started on `pressed` must be discarded.
    case cancelled(HotkeyAction)
}

/// Detects hold-to-talk combinations made only of modifier keys.
/// A combination is active while exactly its modifiers are held. Pressing a regular key
/// or an extra modifier while holding it cancels it, so shortcuts like ⌃⇧Tab still work normally.
public struct HotkeyStateMachine {
    public var talkCombination: ModifierKeys
    public var dictationCombination: ModifierKeys?

    private var activeAction: HotkeyAction?
    /// After a cancel, nothing starts again until all modifiers are released.
    private var waitingForAllModifiersReleased = false

    public init(talkCombination: ModifierKeys, dictationCombination: ModifierKeys?) {
        self.talkCombination = talkCombination
        self.dictationCombination = dictationCombination
    }

    public mutating func handleModifiersChanged(_ currentlyHeldModifiers: ModifierKeys) -> [HotkeyEvent] {
        if currentlyHeldModifiers.isEmpty {
            waitingForAllModifiersReleased = false
        }

        if let activeAction {
            let activeCombination = combination(for: activeAction)
            if currentlyHeldModifiers == activeCombination { return [] }
            self.activeAction = nil
            if currentlyHeldModifiers.isSuperset(of: activeCombination) {
                // An extra modifier joined: the user is typing a shortcut, not talking.
                waitingForAllModifiersReleased = true
                return [.cancelled(activeAction)]
            }
            return [.released(activeAction)]
        }

        guard !waitingForAllModifiersReleased else { return [] }
        if currentlyHeldModifiers == talkCombination {
            activeAction = .talk
            return [.pressed(.talk)]
        }
        if let dictationCombination, currentlyHeldModifiers == dictationCombination {
            activeAction = .dictate
            return [.pressed(.dictate)]
        }
        return []
    }

    public mutating func handleRegularKeyPressed() -> [HotkeyEvent] {
        guard let activeAction else { return [] }
        self.activeAction = nil
        waitingForAllModifiersReleased = true
        return [.cancelled(activeAction)]
    }

    private func combination(for action: HotkeyAction) -> ModifierKeys {
        switch action {
        case .talk: return talkCombination
        case .dictate: return dictationCombination ?? []
        }
    }
}
