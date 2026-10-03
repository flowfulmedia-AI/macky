import XCTest
@testable import MackyCore

final class RoutineTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testScheduleDueness() {
        // Wednesday 30 Sep 2026.
        let schedule = RoutineSchedule(isEnabled: true, hour: 9, minute: 0, weekdays: RoutineSchedule.workdays)
        XCTAssertFalse(schedule.isDue(now: date(2026, 9, 30, 8, 59), lastRunAt: date(2026, 9, 29, 9, 0), calendar: calendar))
        XCTAssertTrue(schedule.isDue(now: date(2026, 9, 30, 9, 0), lastRunAt: date(2026, 9, 29, 9, 0), calendar: calendar))
        XCTAssertTrue(schedule.isDue(now: date(2026, 9, 30, 10, 30), lastRunAt: nil, calendar: calendar))
        // Already ran today.
        XCTAssertFalse(schedule.isDue(now: date(2026, 9, 30, 9, 5), lastRunAt: date(2026, 9, 30, 9, 0), calendar: calendar))
        // Mac asleep until the afternoon: too late to be useful.
        XCTAssertFalse(schedule.isDue(now: date(2026, 9, 30, 15, 0), lastRunAt: nil, calendar: calendar))
        // Saturday: not a workday.
        XCTAssertFalse(schedule.isDue(now: date(2026, 10, 3, 9, 10), lastRunAt: nil, calendar: calendar))
        var disabled = schedule
        disabled.isEnabled = false
        XCTAssertFalse(disabled.isDue(now: date(2026, 9, 30, 9, 0), lastRunAt: nil, calendar: calendar))
    }

    func testMostRecentOccurrenceSkipsDays() {
        let mondays = RoutineSchedule(isEnabled: true, hour: 8, minute: 30, weekdays: [2])
        XCTAssertEqual(mondays.mostRecentOccurrence(atOrBefore: date(2026, 9, 30, 12, 0), calendar: calendar), date(2026, 9, 28, 8, 30))
    }

    func testDescriptions() {
        XCTAssertEqual(RoutineSchedule(isEnabled: true, hour: 9, minute: 0, weekdays: RoutineSchedule.workdays).shortDescription, "luni–vineri la 09:00")
        XCTAssertEqual(RoutineSchedule(isEnabled: true, hour: 7, minute: 5, weekdays: [1, 7]).shortDescription, "Sâ, Du la 07:05")
    }

    func testPhraseMatching() {
        let routines = [Routine.morningBriefExample, Routine.workModeExample]
        XCTAssertEqual(RoutineMatcher.match("Brief de dimineață", in: routines)?.name, "Brief de dimineață")
        XCTAssertEqual(RoutineMatcher.match("Macky, brief de dimineață te rog.", in: routines)?.name, "Brief de dimineață")
        XCTAssertEqual(RoutineMatcher.match("Pornește mod lucru", in: routines)?.name, "Mod lucru")
        XCTAssertNil(RoutineMatcher.match("Ce e un brief de dimineață?", in: routines))
        XCTAssertNil(RoutineMatcher.match("Mi-ai făcut brief de dimineață", in: routines))
        XCTAssertNil(RoutineMatcher.match("scrie-mi un brief de dimineață pentru echipa de marketing", in: routines))
        var disabled = Routine.workModeExample
        disabled.isEnabled = false
        XCTAssertNil(RoutineMatcher.match("mod lucru", in: [disabled]))
    }

    func testRoutineRoundTripsAndRequest() throws {
        let routine = Routine.morningBriefExample
        let decoded = try JSONDecoder().decode(Routine.self, from: JSONEncoder().encode(routine))
        XCTAssertEqual(decoded, routine)
        XCTAssertTrue(routine.requestText.contains("Brief de dimineață"))
        XCTAssertTrue(routine.requestText.contains("mailurile importante"))
    }

    func testMonthlySchedule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let schedule = RoutineSchedule(isEnabled: true, hour: 9, minute: 0, weekdays: [], dayOfMonth: 1)
        func date(_ month: Int, _ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))! }
        XCTAssertTrue(schedule.isDue(now: date(10, 1, 9), lastRunAt: date(9, 1, 9), calendar: calendar))
        XCTAssertFalse(schedule.isDue(now: date(10, 1, 8), lastRunAt: date(9, 1, 9), calendar: calendar))
        // The Mac was off on the 1st: still runs on the 3rd, not on the 10th.
        XCTAssertTrue(schedule.isDue(now: date(10, 3, 12), lastRunAt: date(9, 1, 9), calendar: calendar))
        XCTAssertFalse(schedule.isDue(now: date(10, 10, 12), lastRunAt: date(9, 1, 9), calendar: calendar))
        XCTAssertFalse(schedule.isDue(now: date(10, 2, 12), lastRunAt: date(10, 1, 9), calendar: calendar))
        // "Last day" in a 30-day month.
        let lastDay = RoutineSchedule(isEnabled: true, hour: 9, minute: 0, weekdays: [], dayOfMonth: 31)
        XCTAssertTrue(lastDay.isDue(now: date(9, 30, 10), lastRunAt: nil, calendar: calendar))
        XCTAssertEqual(schedule.shortDescription, "lunar, pe 1, la 09:00")
        // Saved routines without the new field still load.
        let old = try JSONDecoder().decode(RoutineSchedule.self, from: Data(#"{"isEnabled":true,"hour":9,"minute":0,"weekdays":[2]}"#.utf8))
        XCTAssertNil(old.dayOfMonth)
    }
}
