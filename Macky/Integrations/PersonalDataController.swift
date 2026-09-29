import EventKit
import MackyCore

/// Reads and writes the user's Calendar and Reminders directly through EventKit.
/// macOS asks for permission the first time each is used.
@MainActor
final class PersonalDataController {
    private let eventStore = EKEventStore()

    // MARK: Calendar

    func createEvent(_ request: CalendarEventRequest) async -> IntegrationOutcome {
        guard await ensureAccess(to: .event) else { return Self.permissionMissing(for: "Calendar") }
        let event = EKEvent(eventStore: eventStore)
        event.title = request.title
        event.startDate = request.startDate
        event.endDate = request.endDate
        event.isAllDay = request.isAllDay
        event.location = request.location
        event.notes = request.notes
        event.calendar = eventStore.defaultCalendarForNewEvents
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return IntegrationOutcome(succeeded: true, message: "Am adăugat „\(request.title)” în calendar, \(FlexibleDateParser.shortDescription(of: request.startDate)).")
        } catch {
            return IntegrationOutcome(succeeded: false, message: "Nu am putut salva evenimentul: \(error.localizedDescription)")
        }
    }

    func listEvents(from startDate: Date, to endDate: Date) async -> IntegrationOutcome {
        guard await ensureAccess(to: .event) else { return Self.permissionMissing(for: "Calendar") }
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else {
            return IntegrationOutcome(succeeded: true, message: "Nu ai niciun eveniment în acest interval.")
        }
        let lines = events.prefix(30).map { event -> String in
            let time = event.isAllDay ? "toată ziua" : FlexibleDateParser.shortDescription(of: event.startDate)
            let location = (event.location?.isEmpty == false) ? " @ \(event.location!)" : ""
            return "• \(time): \(event.title ?? "(fără titlu)")\(location)"
        }
        return IntegrationOutcome(succeeded: true, message: "Evenimente (\(events.count)):\n" + lines.joined(separator: "\n"))
    }

    // MARK: Reminders

    func createReminder(title: String, dueDate: Date?, notes: String?) async -> IntegrationOutcome {
        guard await ensureAccess(to: .reminder) else { return Self.permissionMissing(for: "Reminders") }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            // The alarm is what makes the reminder actually pop up at that time.
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }
        do {
            try eventStore.save(reminder, commit: true)
            let when = dueDate.map { ", \(FlexibleDateParser.shortDescription(of: $0))" } ?? ""
            return IntegrationOutcome(succeeded: true, message: "Am pus reminder „\(title)”\(when).")
        } catch {
            return IntegrationOutcome(succeeded: false, message: "Nu am putut salva reminderul: \(error.localizedDescription)")
        }
    }

    func listReminders(limit: Int) async -> IntegrationOutcome {
        guard await ensureAccess(to: .reminder) else { return Self.permissionMissing(for: "Reminders") }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let lines: [String] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { @Sendable reminders in
                // Converted to text right here: EKReminder objects must not leave this callback's thread.
                let sortedReminders = (reminders ?? []).sorted { first, second in
                    let firstDate = first.dueDateComponents?.date ?? .distantFuture
                    let secondDate = second.dueDateComponents?.date ?? .distantFuture
                    return firstDate < secondDate
                }
                let descriptions = sortedReminders.prefix(limit).map { reminder -> String in
                    let due = reminder.dueDateComponents?.date.map { " (\(FlexibleDateParser.shortDescription(of: $0)))" } ?? ""
                    return "• \(reminder.title ?? "(fără titlu)")\(due)"
                }
                continuation.resume(returning: descriptions)
            }
        }
        guard !lines.isEmpty else {
            return IntegrationOutcome(succeeded: true, message: "Nu ai niciun reminder deschis.")
        }
        return IntegrationOutcome(succeeded: true, message: "Remindere:\n" + lines.joined(separator: "\n"))
    }

    // MARK: Permission

    private func ensureAccess(to entityType: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: entityType) {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                return entityType == .event
                    ? try await eventStore.requestFullAccessToEvents()
                    : try await eventStore.requestFullAccessToReminders()
            } catch {
                return false
            }
        default:
            return false
        }
    }

    private static func permissionMissing(for applicationName: String) -> IntegrationOutcome {
        IntegrationOutcome(
            succeeded: false,
            message: "Macky nu are acces la \(applicationName). Permite-l în System Settings → Privacy & Security → \(applicationName)."
        )
    }
}
