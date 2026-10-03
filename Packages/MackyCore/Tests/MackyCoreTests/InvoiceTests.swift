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
        let query = InvoiceKit.query(service: "Apple (iCloud / App Store)", start: range.start, end: range.end, calendar: utc)
        XCTAssertEqual(query, "from:(apple) subject:(invoice OR receipt OR factura OR factură OR facturi OR chitanta OR chitanță) after:2026/09/01 before:2026/10/01")
        let imap = IMAPKit.searchCriteria(fromGmailQuery: query)
        XCTAssertTrue(imap.hasPrefix("FROM \"apple\" OR OR OR OR OR OR SUBJECT \"invoice\" SUBJECT \"receipt\""), imap)
        XCTAssertTrue(imap.hasSuffix("SINCE 01-Sep-2026 BEFORE 01-Oct-2026"), imap)
        let googleOne = InvoiceKit.query(service: "Google One", start: range.start, end: range.end, calendar: utc)
        XCTAssertTrue(googleOne.hasPrefix("from:(google) \"google one\" subject:("), googleOne)
        XCTAssertEqual(IMAPKit.searchCriteria(fromGmailQuery: "from:canva -subject:newsletter"), "FROM \"canva\" NOT SUBJECT \"newsletter\"")
    }

    func testOnlyRealBillsPass() {
        let apple = InvoiceKit.profile(for: "Apple (iCloud / App Store)")
        XCTAssertEqual(apple.displayName, "Apple")
        XCTAssertTrue(InvoiceKit.isInvoice(from: "Apple <no_reply@email.apple.com>", subject: "Your receipt from Apple.", attachmentNames: [], text: "", profile: apple))
        // Mentions Apple but is not from Apple, or is from Apple but not a bill.
        XCTAssertFalse(InvoiceKit.isInvoice(from: "Newsletter <news@shop.ro>", subject: "Apple receipt deals", attachmentNames: [], text: "", profile: apple))
        XCTAssertFalse(InvoiceKit.isInvoice(from: "Apple <news@insideapple.apple.com>", subject: "Meet the new iPhone", attachmentNames: [], text: "", profile: apple))

        let lovable = InvoiceKit.profile(for: "Lovable")
        XCTAssertTrue(InvoiceKit.isInvoice(from: "Lovable <invoice+statements@stripe.com>", subject: "Your Lovable payment",
                                           attachmentNames: ["Invoice-1234.pdf"], text: "", profile: lovable))
        XCTAssertFalse(InvoiceKit.isInvoice(from: "Ana <ana@gmail.com>", subject: "Factura Lovable", attachmentNames: [], text: "", profile: lovable))

        let captions = InvoiceKit.profile(for: "Captions.ai")
        XCTAssertEqual(captions.searchWords, ["captions"])

        let zoom = InvoiceKit.profile(for: "Zoom")
        XCTAssertFalse(InvoiceKit.isInvoice(from: "Ion <ion@firma.ro>", subject: "Invoice pentru meetingul pe Zoom", attachmentNames: [], text: "", profile: zoom))
        XCTAssertTrue(InvoiceKit.isInvoice(from: "Zoom <billing@zoom.us>", subject: "Zoom Invoice", attachmentNames: [], text: "", profile: zoom))

        let googleOne = InvoiceKit.profile(for: "Google One")
        XCTAssertFalse(InvoiceKit.isInvoice(from: "Google Play <googleplay-noreply@google.com>", subject: "Your Google Play order receipt", attachmentNames: [], text: "YouTube Premium", profile: googleOne))
        XCTAssertTrue(InvoiceKit.isInvoice(from: "Google Play <googleplay-noreply@google.com>", subject: "Your Google Play order receipt", attachmentNames: [], text: "Google One 100 GB", profile: googleOne))
    }

    func testFileNames() {
        let date = utc.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        XCTAssertEqual(InvoiceKit.fileName(template: "", service: "Lovable", date: date, calendar: utc), "Factura Lovable (SEP 2026)")
        XCTAssertEqual(InvoiceKit.fileName(template: "{AN}-{luna} {serviciu}/{Luna}", service: "Canva", date: date, calendar: utc), "2026-sep Canva Septembrie")
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
