import XCTest
@testable import MackyCore

final class InvoiceTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testAliasesAndMonths() {
        XCTAssertEqual(InvoiceKit.aliases(for: "Apple (iCloud / App Store)"), ["Apple", "iCloud", "App Store"])
        XCTAssertEqual(InvoiceKit.aliases(for: "Captions.ai"), ["Captions.ai"])
        for text in ["2026-09", "09/2026", "septembrie 2026", "Sept 2026"] {
            let range = InvoiceKit.monthRange(text, calendar: utc)
            XCTAssertEqual(range.map { utc.dateComponents([.year, .month, .day], from: $0.start) }, DateComponents(year: 2026, month: 9, day: 1), text)
            XCTAssertEqual(range.map { utc.component(.month, from: $0.end) }, 10, text)
        }
        XCTAssertNil(InvoiceKit.monthRange("factura"))
    }

    func testQueryWorksForGmailAndIMAP() throws {
        let range = try XCTUnwrap(InvoiceKit.monthRange("2026-09", calendar: utc))
        let query = InvoiceKit.query(service: "Apple (App Store)", start: range.start, end: range.end, calendar: utc)
        XCTAssertTrue(query.hasPrefix("{from:apple subject:apple \"app store\"} {invoice receipt"))
        XCTAssertTrue(query.hasSuffix("after:2026/09/01 before:2026/10/01"))
        let imap = IMAPKit.searchCriteria(fromGmailQuery: query)
        XCTAssertTrue(imap.hasPrefix("OR OR FROM \"apple\" SUBJECT \"apple\" TEXT \"app store\""), imap)
        XCTAssertTrue(imap.hasSuffix("SINCE 01-Sep-2026 BEFORE 01-Oct-2026"), imap)
    }

    func testIdentifiersAndAmounts() {
        XCTAssertEqual(InvoiceKit.identifiers(inSearchLines: ["id=18c1 | Tue | from: a", "id=gmail:ana@gmail.com#9 | account: x", "Gmail search failed", "id=imap:b@yahoo.com#5 | x"]),
                       ["18c1", "gmail:ana@gmail.com#9", "imap:b@yahoo.com#5"])
        XCTAssertEqual(InvoiceKit.amount(in: "Plan Pro\nSubtotal $20.00\nTotal $24.20\n"), "$24.20")
        XCTAssertEqual(InvoiceKit.amount(in: "TOTAL\n12,99 €"), "12,99 €")
        XCTAssertEqual(InvoiceKit.amount(in: "Ai plătit 49,00 lei pentru abonament"), "49,00 lei")
        XCTAssertNil(InvoiceKit.amount(in: "Mulțumim!"))
    }

    func testSummary() {
        let text = InvoiceKit.summary(title: "Facturi septembrie 2026", entries: [
            .init(service: "Canva", date: nil, subject: "Your receipt", sender: "Canva", amount: "12 EUR", files: ["invoice.pdf"])
        ], servicesWithoutInvoices: ["Zoom"])
        XCTAssertTrue(text.contains("Canva\n  • fără dată — Your receipt — 12 EUR"))
        XCTAssertTrue(text.contains("Nu am găsit facturi pentru: Zoom"))
    }
}
