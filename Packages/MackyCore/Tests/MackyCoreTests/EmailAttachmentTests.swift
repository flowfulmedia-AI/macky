import XCTest
@testable import MackyCore

final class EmailAttachmentTests: XCTestCase {
    private let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0xE2, 0x80, 0x99, 0xFF, 0x00, 0x01])

    func testFindsThePDFAndSkipsTheInlineLogo() {
        let raw = """
        From: =?UTF-8?Q?Canva?= <billing@canva.com>\r
        Subject: =?UTF-8?B?RmFjdHVyxIMgb2N0b21icmll?=\r
        Date: Thu, 1 Oct 2026 09:00:00 +0300 (EEST)\r
        Content-Type: multipart/mixed; boundary="outer"\r
        \r
        preamble\r
        --outer\r
        Content-Type: multipart/related; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <p>Mul=C8=9Bumim! Total: 12 EUR</p>\r
        --inner\r
        Content-Type: image/png; name="logo.png"\r
        Content-Disposition: inline; filename="logo.png"\r
        Content-ID: <logo>\r
        Content-Transfer-Encoding: base64\r
        \r
        iVBORw0KGgo=\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name="invoice.pdf"\r
        Content-Disposition: attachment; filename*=UTF-8''factur%C4%83%20123.pdf\r
        Content-Transfer-Encoding: base64\r
        \r
        \(pdfBytes.base64EncodedString(options: .lineLength64Characters))\r
        --outer--\r
        """
        let email = EmailFiles.parse(rawMessage: Data(raw.utf8))
        XCTAssertEqual(email.subject, "Factură octombrie")
        XCTAssertEqual(email.attachments.count, 2)
        let documents = email.attachments.filter(\.isDocument)
        XCTAssertEqual(documents.map(\.fileName), ["factură 123.pdf"])
        XCTAssertEqual(documents.first?.data, pdfBytes)
        XCTAssertTrue(email.html.contains("Mulțumim! Total: 12 EUR"))
        XCTAssertEqual(EmailFiles.documentName(for: email), "2026-10-01 Canva - Factură octombrie.pdf")
    }

    func testPlainEmailBecomesHTML() {
        let raw = "From: Apple <no_reply@email.apple.com>\nSubject: Your receipt\nContent-Type: text/plain; charset=utf-8\n\nTotal <5 EUR>"
        let email = EmailFiles.parse(rawMessage: Data(raw.utf8))
        XCTAssertTrue(email.attachments.isEmpty)
        XCTAssertTrue(email.html.contains("Total &lt;5 EUR&gt;"))
    }

    func testFileAndFolderNames() {
        XCTAssertEqual(EmailFiles.safeFileName("a/b:c?.pdf"), "a b c .pdf")
        XCTAssertEqual(EmailFiles.uniqueFileName("f.pdf") { ["f.pdf", "f (2).pdf"].contains($0) }, "f (3).pdf")
        let home = "/Users/ana"
        XCTAssertEqual(EmailFiles.folderPath(for: "Facturi Octombrie 2026", homeDirectory: home), "/Users/ana/Downloads/Facturi Octombrie 2026")
        XCTAssertEqual(EmailFiles.folderPath(for: "~/Downloads/Facturi", homeDirectory: home), "/Users/ana/Downloads/Facturi")
        XCTAssertEqual(EmailFiles.folderPath(for: "Documents/Firma/Facturi", homeDirectory: home), "/Users/ana/Documents/Firma/Facturi")
        XCTAssertEqual(EmailFiles.folderPath(for: "/etc/x", homeDirectory: home), "/Users/ana/Downloads/x")
        XCTAssertEqual(EmailFiles.folderPath(for: "../../etc", homeDirectory: home), "/Users/ana/Downloads/etc")
    }

    func testToolCallParsing() {
        let call = ChatToolCall(identifier: "1", name: "save_email_attachments", argumentsJSON: #"{"ids":["gmail:ana@gmail.com#1","imap:x@yahoo.com#5"],"folder":"Facturi oct"}"#)
        XCTAssertEqual(ScreenAction(toolCall: call), .saveEmailAttachments(identifiers: ["gmail:ana@gmail.com#1", "imap:x@yahoo.com#5"], folder: "Facturi oct", savesEmailWithoutAttachment: true))
        let joined = ChatToolCall(identifier: "2", name: "save_email_attachments", argumentsJSON: #"{"ids":"a1, b2","folder":"F","save_email_if_no_attachment":false}"#)
        XCTAssertEqual(ScreenAction(toolCall: joined), .saveEmailAttachments(identifiers: ["a1", "b2"], folder: "F", savesEmailWithoutAttachment: false))
    }

    func testGmailRawMessage() {
        let message = "Subject: ok?\n\n>>>"
        let base64URL = Data(message.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let json = Data(#"{"id":"1","raw":"\#(base64URL)"}"#.utf8)
        XCTAssertEqual(GmailAPI.parseRawMessage(json).map { String(decoding: $0, as: UTF8.self) }, message)
    }
}
