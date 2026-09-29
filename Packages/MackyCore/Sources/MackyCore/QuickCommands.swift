import Foundation

public enum MediaKey: String, Equatable, Sendable {
    case playPause
    case nextTrack
    case previousTrack

    public var displayName: String {
        switch self {
        case .playPause: return "Play / pauză"
        case .nextTrack: return "Melodia următoare"
        case .previousTrack: return "Melodia anterioară"
        }
    }
}

/// A command simple enough to run instantly, without a screenshot or a model round trip.
public struct QuickCommand: Equatable, Sendable {
    public var action: ScreenAction
    /// What Macky says, e.g. "Sigur!".
    public var acknowledgement: String

    public init(action: ScreenAction, acknowledgement: String) {
        self.action = action
        self.acknowledgement = acknowledgement
    }
}

/// Recognizes short, unambiguous spoken commands in Romanian and English.
/// Anything longer or less certain goes to the model instead, so a false match is unlikely.
public enum QuickCommandMatcher {
    /// Longer requests carry details a pattern cannot handle ("open Safari and search for...").
    private static let maximumWordCount = 6

    public static func match(_ transcript: String) -> QuickCommand? {
        let normalizedText = normalize(transcript)
        guard !normalizedText.isEmpty, normalizedText.split(separator: " ").count <= maximumWordCount else { return nil }

        if mediaPlayPausePhrases.contains(normalizedText) {
            return QuickCommand(action: .mediaKey(.playPause), acknowledgement: "Sigur!")
        }
        if mediaNextPhrases.contains(normalizedText) {
            return QuickCommand(action: .mediaKey(.nextTrack), acknowledgement: "Sigur!")
        }
        if mediaPreviousPhrases.contains(normalizedText) {
            return QuickCommand(action: .mediaKey(.previousTrack), acknowledgement: "Sigur!")
        }

        for openVerb in openVerbs {
            let prefix = openVerb + " "
            guard normalizedText.hasPrefix(prefix) else { continue }
            var applicationName = String(normalizedText.dropFirst(prefix.count))
            for filler in ["aplicatia ", "aplicația ", "app ", "the app ", "te rog ", "please "] where applicationName.hasPrefix(filler) {
                applicationName = String(applicationName.dropFirst(filler.count))
            }
            for filler in [" te rog", " please", " acum", " now"] where applicationName.hasSuffix(filler) {
                applicationName = String(applicationName.dropLast(filler.count))
            }
            applicationName = applicationName.trimmingCharacters(in: .whitespaces)
            // A single short name; "deschide un fișier nou" is not an app name.
            guard !applicationName.isEmpty, applicationName.split(separator: " ").count <= 3,
                  !notApplicationNames.contains(where: { applicationName.hasPrefix($0) }) else { return nil }
            return QuickCommand(action: .openApplication(name: applicationName), acknowledgement: "Sigur, deschid acum!")
        }
        return nil
    }

    /// Lowercased, without punctuation and without polite fillers at the ends.
    static func normalize(_ text: String) -> String {
        var normalizedText = text.lowercased()
        normalizedText = normalizedText.replacingOccurrences(of: #"[.,!?;:„”"«»]"#, with: " ", options: .regularExpression)
        normalizedText = normalizedText.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        normalizedText = normalizedText.trimmingCharacters(in: .whitespaces)
        for leadingFiller in ["macky ", "hei ", "hey ", "te rog ", "please ", "poti sa ", "poți să ", "poti ", "poți "] where normalizedText.hasPrefix(leadingFiller) {
            normalizedText = String(normalizedText.dropFirst(leadingFiller.count))
        }
        for trailingFiller in [" te rog", " please", " macky"] where normalizedText.hasSuffix(trailingFiller) {
            normalizedText = String(normalizedText.dropLast(trailingFiller.count))
        }
        return normalizedText.trimmingCharacters(in: .whitespaces)
    }

    static let mediaPlayPausePhrases: Set<String> = [
        "pauza", "pauză", "pune pauza", "pune pauză", "da pauza", "dă pauză", "opreste muzica", "oprește muzica",
        "opreste melodia", "oprește melodia", "stop muzica", "porneste muzica", "pornește muzica", "pune muzica",
        "play", "pause", "play music", "pause music", "stop the music", "resume", "continua muzica", "continuă muzica"
    ]
    static let mediaNextPhrases: Set<String> = [
        "urmatoarea", "următoarea", "urmatoarea melodie", "următoarea melodie", "urmatoarea piesa", "următoarea piesă",
        "melodia urmatoare", "melodia următoare", "piesa urmatoare", "piesa următoare", "da mai departe", "dă mai departe",
        "next", "next song", "next track", "skip", "skip song"
    ]
    static let mediaPreviousPhrases: Set<String> = [
        "melodia anterioara", "melodia anterioară", "piesa anterioara", "piesa anterioară", "melodia de dinainte",
        "inapoi la melodia anterioara", "înapoi la melodia anterioară", "previous", "previous song", "previous track", "go back a song"
    ]
    static let openVerbs = ["deschide", "deschide-mi", "porneste", "pornește", "lanseaza", "lansează", "open", "launch", "start"]
    /// Things that follow "deschide" but are not apps; these need the model.
    static let notApplicationNames = [
        "un ", "o ", "fisier", "fișier", "folder", "dosar", "tab", "pagina", "pagină", "site", "link", "fereastra", "fereastră",
        "melodia", "muzica", "muzică", "setarile", "setările", "a ", "an ", "the ", "new ", "file", "window", "settings"
    ]
}

/// "Agent, caută…" / "În fundal: compară…" start a background job directly, without the model deciding.
public enum BackgroundTaskTrigger {
    private static let leadingTriggerPattern = #"^\s*(macky[\s,]+)?(agentule|agent|[îi]n fundal|in background|background agent)\b[\s,:;!.-]*"#
    private static let trailingTriggerPattern = #"[\s,]+([îi]n fundal|in the background)[\s.!]*$"#

    public static func goal(from transcript: String) -> String? {
        for pattern in [leadingTriggerPattern, trailingTriggerPattern] {
            guard let range = transcript.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            var goal = transcript
            goal.removeSubrange(range)
            goal = goal.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:;!")))
            // "Agent" alone is not a task.
            return goal.split(separator: " ").count >= 2 ? goal : nil
        }
        return nil
    }
}
