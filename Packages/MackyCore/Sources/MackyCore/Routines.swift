import Foundation

/// When a routine runs by itself.
public struct RoutineSchedule: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int
    /// Calendar weekday numbers: 1 = Sunday, 2 = Monday … 7 = Saturday.
    public var weekdays: Set<Int>

    public static let workdays: Set<Int> = [2, 3, 4, 5, 6]
    public static let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    public init(isEnabled: Bool, hour: Int, minute: Int, weekdays: Set<Int>) {
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    /// The latest scheduled moment at or before `now` (today or an earlier day), if any in the last week.
    public func mostRecentOccurrence(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
        for daysBack in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: now),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let occurrence = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  occurrence <= now else { continue }
            return occurrence
        }
        return nil
    }

    /// Due when a scheduled time passed since the last run, within a grace period
    /// (the Mac may have been asleep at 9:00; at 9:20 the brief is still useful, at 15:00 it is not).
    public func isDue(now: Date, lastRunAt: Date?, gracePeriod: TimeInterval = 2 * 3600, calendar: Calendar = .current) -> Bool {
        guard isEnabled, let occurrence = mostRecentOccurrence(atOrBefore: now, calendar: calendar),
              now.timeIntervalSince(occurrence) <= gracePeriod else { return false }
        guard let lastRunAt else { return true }
        return lastRunAt < occurrence
    }

    public var shortDescription: String {
        let names = [1: "Du", 2: "Lu", 3: "Ma", 4: "Mi", 5: "Jo", 6: "Vi", 7: "Sâ"]
        let days: String
        if weekdays == Self.everyDay {
            days = "zilnic"
        } else if weekdays == Self.workdays {
            days = "luni–vineri"
        } else {
            days = [2, 3, 4, 5, 6, 7, 1].filter(weekdays.contains).compactMap { names[$0] }.joined(separator: ", ")
        }
        return String(format: "%@ la %02d:%02d", days, hour, minute)
    }
}

/// Something the user set up once and Macky does on a phrase or on a schedule, e.g. the morning brief.
public struct Routine: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Saying one of these starts the routine ("brief de dimineață", "mod lucru").
    public var triggerPhrases: [String]
    public var schedule: RoutineSchedule
    /// What to do, in the user's words.
    public var instructions: String
    public var speaksResult: Bool
    public var lastRunAt: Date?

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, triggerPhrases: [String], schedule: RoutineSchedule,
                instructions: String, speaksResult: Bool = true, lastRunAt: Date? = nil) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.triggerPhrases = triggerPhrases
        self.schedule = schedule
        self.instructions = instructions
        self.speaksResult = speaksResult
        self.lastRunAt = lastRunAt
    }

    /// The request given to the model when the routine runs.
    public var requestText: String {
        """
        Run my routine "\(name)" now. My instructions for it:
        \(instructions)

        Use your tools to do it and to gather what it needs (calendar, reminders, Gmail, web, memory). \
        Then give me a short, natural spoken summary: it is read aloud, so no lists or headings. \
        Skip anything you cannot access instead of apologizing at length.
        """
    }

    public static let morningBriefExample = Routine(
        name: "Brief de dimineață",
        triggerPhrases: ["brief de dimineață", "briefing", "brief-ul de azi"],
        schedule: RoutineSchedule(isEnabled: false, hour: 9, minute: 0, weekdays: RoutineSchedule.workdays),
        instructions: """
        Spune-mi ce am azi:
        - întâlnirile din calendar de azi, cu ora;
        - reminderele de azi și cele întârziate;
        - mailurile importante necitite din ultimele 24 de ore (de la clienți sau care cer un răspuns), pe scurt, cine și ce vrea;
        - mesajele WhatsApp necitite, pe scurt, de la cine și ce vor (dacă WhatsApp e conectat);
        - vremea de azi în orașul meu (din memorie; dacă nu îl știi, sari peste).
        Începe cu cel mai important lucru. Maximum 6 propoziții.
        """
    )

    public static let workModeExample = Routine(
        name: "Mod lucru",
        triggerPhrases: ["mod lucru", "hai la treabă", "mod de lucru"],
        schedule: RoutineSchedule(isEnabled: false, hour: 9, minute: 30, weekdays: RoutineSchedule.workdays),
        instructions: """
        Deschide Gmail în Chrome, apoi Notes. Pune Chrome în stânga și Notes în dreapta.
        Pornește pe Spotify un playlist de concentrare (de exemplu „Deep Focus”).
        """,
        speaksResult: false
    )
}

public enum RoutineMatcher {
    /// The enabled routine whose phrase the user said. The whole request must be about little more than
    /// the phrase, so "ce e un brief de dimineață?" does not start the routine.
    public static func match(_ transcript: String, in routines: [Routine]) -> Routine? {
        let spoken = normalize(transcript)
        guard !spoken.isEmpty else { return nil }
        let spokenWordCount = spoken.split(separator: " ").count
        for routine in routines where routine.isEnabled {
            for phrase in routine.triggerPhrases.map(normalize) where !phrase.isEmpty {
                let phraseWordCount = phrase.split(separator: " ").count
                if spoken == phrase { return routine }
                // "pornește modul lucru te rog", "Macky, brief de dimineață".
                if (" " + spoken + " ").contains(" " + phrase + " ") && spokenWordCount <= phraseWordCount + 3 && !spoken.hasSuffix("?") {
                    return routine
                }
            }
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let keepsQuestionMark = folded.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted).filter { !$0.isEmpty }
        return words.joined(separator: " ") + (keepsQuestionMark ? "?" : "")
    }
}
