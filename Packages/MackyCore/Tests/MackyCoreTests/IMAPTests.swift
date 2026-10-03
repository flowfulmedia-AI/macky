@testable import MackyCore
import XCTest

final class IMAPTests: XCTestCase {
    func testGmailQueryTranslation() {
        let now = ISO8601DateFormatter().date(from: "2026-10-03T10:00:00Z")!
        XCTAssertEqual(IMAPKit.searchCriteria(fromGmailQuery: "from:andrei is:unread newer_than:2d factura", now: now),
                       "FROM \"andrei\" UNSEEN SINCE 01-Oct-2026 TEXT \"factura\"")
        XCTAssertEqual(IMAPKit.searchCriteria(fromGmailQuery: "subject:\"oferta nouă\" after:2026/09/01 in:inbox"),
                       "SUBJECT \"oferta nouă\" SINCE 01-Sep-2026")
        XCTAssertEqual(IMAPKit.searchCriteria(fromGmailQuery: ""), "ALL")
        XCTAssertEqual(IMAPKit.quoted("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    func testResponsesWithLiteralsAndPartialData() {
        let header = "From: =?UTF-8?B?QW5hIFBvcA==?= <ana@yahoo.com>\r\nSubject: =?utf-8?Q?Ofert=C4=83_nou=C4=83?=\r\nDate: Fri, 2 Oct 2026 09:00:00 +0300\r\n\r\n"
        let body = "Salut, iti trimit oferta."
        let raw = "* SEARCH 3 7\r\n* 1 FETCH (UID 7 FLAGS (\\Seen) BODY[HEADER] {\(header.utf8.count)}\r\n\(header) BODY[TEXT] {\(body.utf8.count)}\r\n\(body))\r\na4 OK done\r\n* 2 FETCH (UID 9 BODY[HEADER] {50}\r\nincomplete"
        let (responses, remainder) = IMAPKit.splitResponses(Data(raw.utf8))
        XCTAssertEqual(IMAPKit.searchResults(in: responses), [3, 7])
        XCTAssertEqual(IMAPKit.completion(of: "a4", in: responses)?.ok, true)
        XCTAssertTrue(String(decoding: remainder, as: UTF8.self).hasPrefix("* 2 FETCH"))
        let items = IMAPKit.fetchedItems(in: responses)
        XCTAssertEqual(items.count, 1)
        let message = IMAPKit.message(from: items[0])
        XCTAssertEqual(message.uid, 7)
        XCTAssertEqual(message.from, "Ana Pop <ana@yahoo.com>")
        XCTAssertEqual(message.subject, "Ofertă nouă")
        XCTAssertFalse(message.isUnread)
        XCTAssertEqual(message.bodyText, body)
    }

    func testMultipartQuotedPrintable() {
        let headers = MIME.headers("Content-Type: multipart/alternative;\r\n boundary=\"XX\"\r\n\r\n")
        let body = "--XX\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nBun=C4=83 ziua,=\r\n mul=C8=9Bumesc!\r\n--XX\r\nContent-Type: text/html\r\n\r\n<p>html</p>\r\n--XX--\r\n"
        XCTAssertEqual(MIME.readableText(headers: headers, body: body), "Bună ziua, mulțumesc!")
        let htmlOnly = MIME.readableText(headers: ["content-type": "text/html; charset=utf-8"], body: "<p>Salut <b>Darius</b></p>")
        XCTAssertTrue(htmlOnly.contains("Salut"))
        XCTAssertEqual(IMAPAccount.Provider.guess(for: "ion@yahoo.ro"), .yahoo)
        XCTAssertEqual(IMAPAccount.Provider.guess(for: "ion@icloud.com"), .icloud)
    }
}
