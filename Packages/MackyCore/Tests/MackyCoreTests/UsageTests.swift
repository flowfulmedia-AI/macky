import XCTest
@testable import MackyCore

final class UsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    func testLedgerTotals() {
        var ledger = UsageLedger()
        ledger.record(TokenUsage(promptTokens: 100, completionTokens: 10, costInCredits: 0.01), purpose: .questions, date: date(30), calendar: calendar)
        ledger.record(TokenUsage(promptTokens: 100, completionTokens: 10, costInCredits: 0.02), purpose: .meetings, date: date(30), calendar: calendar)
        ledger.record(TokenUsage(promptTokens: 100, completionTokens: 10, costInCredits: 0.07), purpose: .questions, date: date(24), calendar: calendar)
        ledger.record(TokenUsage(promptTokens: 1, completionTokens: 1, costInCredits: nil), purpose: .memory, date: date(29), calendar: calendar)
        let now = date(30, 18)
        XCTAssertEqual(ledger.totalCost(lastDays: 1, now: now, calendar: calendar), 0.03, accuracy: 1e-9)
        XCTAssertEqual(ledger.totalCost(lastDays: 7, now: now, calendar: calendar), 0.10, accuracy: 1e-9)
        XCTAssertEqual(ledger.totalCostThisMonth(now: now, calendar: calendar), 0.10, accuracy: 1e-9)
        XCTAssertEqual(ledger.requestCount(lastDays: 7, now: now, calendar: calendar), 4)
        XCTAssertEqual(ledger.dailyTotals(lastDays: 7, now: now, calendar: calendar).count, 7)
        XCTAssertEqual(ledger.dailyTotals(lastDays: 7, now: now, calendar: calendar).last!.cost, 0.03, accuracy: 1e-9)
        let byPurpose = ledger.costByPurpose(lastDays: 7, now: now, calendar: calendar)
        XCTAssertEqual(byPurpose.map(\.purpose), [.questions, .meetings])
        XCTAssertEqual(ledger.estimatedDaysLeft(remainingCredit: 1.0, now: now, calendar: calendar), 70)
        XCTAssertNil(UsageLedger().estimatedDaysLeft(remainingCredit: 5, now: now, calendar: calendar))
        let decoded = try? JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
    }

    func testKeyUsageAndSuggestions() {
        let usage = OpenRouterKeyUsage.parse(Data(#"{"data":{"label":"x","usage":12.5,"usage_daily":0.4,"usage_weekly":2,"usage_monthly":7.25,"limit":null,"limit_remaining":null}}"#.utf8))
        XCTAssertEqual(usage?.totalUsage, 12.5)
        XCTAssertEqual(usage?.monthlyUsage, 7.25)
        XCTAssertNil(usage?.limit)
        XCTAssertNil(OpenRouterKeyUsage.parse(Data("{}".utf8)))
        let morning = SuggestionCatalog.suggestions(hasGoogle: true, hasTaskApp: true, hasZoom: true, hour: 9)
        XCTAssertEqual(morning.count, 3)
        XCTAssertEqual(morning.first?.text, "Brief de dimineață")
        XCTAssertFalse(SuggestionCatalog.suggestions(hasGoogle: false, hasTaskApp: false, hasZoom: false, hour: 15).contains { $0.text.contains("mailuri") })
    }
}
