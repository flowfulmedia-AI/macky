import Foundation
import MackyCore

/// The user's routines, saved in ~/Library/Application Support/Macky/routines.json, plus the clock that
/// starts scheduled ones. Starts with two editable examples: the morning brief and "Mod lucru".
@MainActor
final class RoutineStore: ObservableObject {
    @Published private(set) var routines: [Routine] = []

    /// Called when a scheduled routine is due. Returns false when Macky is busy, so it is tried again shortly.
    var onRoutineDue: ((Routine) -> Bool)?

    private let fileURL = ApplicationDirectories.applicationSupportDirectory.appendingPathComponent("routines.json")
    private var timer: Timer?

    init() {
        load()
    }

    func startScheduler() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDueRoutines() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        runDueRoutines()
    }

    private func runDueRoutines() {
        let now = Date()
        for routine in routines where routine.isEnabled && routine.schedule.isDue(now: now, lastRunAt: routine.lastRunAt) {
            if onRoutineDue?(routine) == true {
                markRun(routine.id, at: now)
            }
            // One at a time; the next one starts on a later tick.
            return
        }
    }

    func markRun(_ identifier: UUID, at date: Date = Date()) {
        guard let index = routines.firstIndex(where: { $0.id == identifier }) else { return }
        routines[index].lastRunAt = date
        save()
    }

    func upsert(_ routine: Routine) {
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        save()
    }

    func delete(_ identifier: UUID) {
        routines.removeAll { $0.id == identifier }
        save()
    }

    func restoreExamples() {
        for example in [Routine.morningBriefExample, Routine.workModeExample] where !routines.contains(where: { $0.name == example.name }) {
            var copy = example
            copy.id = UUID()
            routines.append(copy)
        }
        save()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let savedRoutines = try? decoder.decode([Routine].self, from: data) {
            routines = savedRoutines
        } else {
            routines = [Routine.morningBriefExample, Routine.workModeExample]
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(routines) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
