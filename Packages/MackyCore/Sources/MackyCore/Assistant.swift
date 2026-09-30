import Foundation

// MARK: - Claude skills

/// A skill exported from Claude (a folder with SKILL.md: YAML front matter with `name` and `description`,
/// then the instructions). Macky lists the skills to the model and loads one when a request matches it.
public struct SkillDefinition: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var instructions: String
    public var sourcePath: String

    public init(name: String, description: String, instructions: String, sourcePath: String) {
        self.name = name
        self.description = description
        self.instructions = instructions
        self.sourcePath = sourcePath
    }
}

public enum SkillParser {
    public static func parse(markdown: String, fallbackName: String, sourcePath: String) -> SkillDefinition? {
        var name = fallbackName
        var description = ""
        var body = markdown
        let lines = markdown.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            var currentKey: String?
            for line in lines[1..<closingIndex] {
                if let colonIndex = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = unquote(line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces))
                    currentKey = key
                    if key == "name", !value.isEmpty { name = value }
                    if key == "description", !["|", ">", "|-", ">-"].contains(value) { description = value }
                } else if currentKey == "description" {
                    // Multi-line (block) description.
                    let continuation = line.trimmingCharacters(in: .whitespaces)
                    if !continuation.isEmpty { description += (description.isEmpty ? "" : " ") + continuation }
                }
            }
            body = lines[(closingIndex + 1)...].joined(separator: "\n")
        }
        let instructions = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty || !description.isEmpty else { return nil }
        if description.isEmpty {
            description = instructions.components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        return SkillDefinition(name: name.trimmingCharacters(in: .whitespaces), description: String(description.prefix(400)),
                               instructions: instructions, sourcePath: sourcePath)
    }

    private static func unquote(_ text: String) -> String {
        var value = text
        if value.count >= 2, let first = value.first, let last = value.last, (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

public enum SkillCatalog {
    /// The list of skills added to the system prompt, within a budget.
    public static func promptSection(for skills: [SkillDefinition], characterBudget: Int = 3000) -> String? {
        guard !skills.isEmpty else { return nil }
        var lines = ["""


        The user's skills (made in Claude). When a request matches a skill's description (for example writing an email, \
        a proposal or a post in the user's style), call use_skill with its name FIRST, then follow the instructions it returns:
        """]
        var used = 0
        for skill in skills.sorted(by: { $0.name < $1.name }) {
            let line = "- \(skill.name): \(skill.description)"
            guard used + line.count <= characterBudget else { break }
            lines.append(line)
            used += line.count
        }
        return lines.joined(separator: "\n")
    }

    public static func find(_ name: String, in skills: [SkillDefinition]) -> SkillDefinition? {
        let wanted = fold(name)
        return skills.first { fold($0.name) == wanted }
            ?? skills.first { fold($0.name).contains(wanted) || wanted.contains(fold($0.name)) }
    }

    /// Instructions given to the model, cut to a size that keeps requests affordable.
    public static func toolResult(for skill: SkillDefinition, maximumCharacters: Int = 12_000) -> String {
        var text = "Skill \"\(skill.name)\". Follow these instructions for the user's request:\n\n"
        text += skill.instructions.count > maximumCharacters ? String(skill.instructions.prefix(maximumCharacters)) + "\n[…truncated]" : skill.instructions
        return text
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Writing assistant

public enum WritingIntent {
    /// Whether the request is probably about text the user selected or is writing, so Macky should try
    /// harder to read the selection (copying it when Accessibility cannot see it).
    public static func mentionsText(_ question: String) -> Bool {
        let folded = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return cues.contains { folded.contains($0) }
    }

    static let cues = [
        "text", "selectat", "selectia", "rescrie", "reformuleaza", "corecteaza", "corectez", "traduce", "tradu", "rezuma", "scurteaza",
        "mai politicos", "mai formal", "mai prietenos", "mai scurt", "mai lung", "raspunde la", "raspuns la", "mesaj", "mail", "email",
        "paragraf", "fraza", "propozitia", "greseli", "gramatica", "ton", "rewrite", "translate", "summarize", "fix the", "reply"
    ]
}

// MARK: - Follow-up listening

/// After Macky answers, it listens a few seconds more so the user can simply reply, without the keys.
public enum FollowUpListeningPolicy {
    public enum Decision: Equatable {
        case keepListening
        /// Nobody spoke: stop quietly.
        case giveUp
        /// The user spoke and paused: transcribe and answer.
        case finish
    }

    public static let windowForQuestion: Double = 8
    public static let defaultWindow: Double = 5
    public static let endOfSpeechPause: Double = 0.8
    public static let maximumDuration: Double = 30

    /// Longer window when Macky just asked the user something.
    public static func listeningWindow(afterAnswer answer: String) -> Double {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ? windowForQuestion : defaultWindow
    }

    public static func decide(detector: SpeechEndpointDetector, elapsedSeconds: Double, window: Double, sampleRate: Double) -> Decision {
        if detector.hasSpeechEnded(minimumPause: endOfSpeechPause, sampleRate: sampleRate) { return .finish }
        if !detector.hasHeardSpeech { return elapsedSeconds >= window ? .giveUp : .keepListening }
        return elapsedSeconds >= maximumDuration ? .finish : .keepListening
    }

    /// Phrases that end the conversation instead of starting a new request.
    public static func isDismissal(_ transcript: String) -> Bool {
        let folded = transcript.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return ["multumesc", "mersi", "ms", "gata", "atat", "atat e tot", "e ok", "ok", "okay", "bine", "nimic", "nu", "thanks", "thank you", "no"].contains(folded)
    }
}
