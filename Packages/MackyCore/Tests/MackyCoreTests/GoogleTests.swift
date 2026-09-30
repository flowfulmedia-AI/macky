import XCTest
@testable import MackyCore

final class GoogleTests: XCTestCase {
    func testAuthorizationURLAndBodies() {
        let url = GoogleOAuth.authorizationURL(clientIdentifier: "abc.apps.googleusercontent.com", redirectURI: "http://127.0.0.1:5000", codeChallenge: "CH", state: "ST")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("access_type"), "offline")
        XCTAssertEqual(value("scope"), "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/drive.file")
        let body = String(data: GoogleOAuth.authorizationCodeRequestBody(code: "4/a b", clientIdentifier: "id", clientSecret: "s", redirectURI: "http://127.0.0.1:5000", codeVerifier: "v"), encoding: .utf8)!
        XCTAssertTrue(body.contains("code=4%2Fa%20b"))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A5000"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
    }

    func testTokenParsingAndCallback() throws {
        let tokens = try GoogleOAuth.parseTokenResponse(Data(#"{"access_token":"A","expires_in":3599,"refresh_token":"R"}"#.utf8))
        XCTAssertEqual(tokens, GoogleOAuth.Tokens(accessToken: "A", refreshToken: "R", expiresInSeconds: 3599))
        XCTAssertThrowsError(try GoogleOAuth.parseTokenResponse(Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8)))
        let callback = GoogleOAuth.parseCallback(requestText: "GET /?state=ST&code=4/0Ab&scope=x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        XCTAssertEqual(callback, GoogleOAuth.AuthorizationCallback(code: "4/0Ab", state: "ST", error: nil))
        XCTAssertEqual(GoogleOAuth.parseCallback(requestText: "GET /?error=access_denied&state=ST HTTP/1.1")?.error, "access_denied")
        XCTAssertNil(GoogleOAuth.parseCallback(requestText: "GET /favicon.ico HTTP/1.1"))
    }

    func testPKCEHelpers() {
        let verifier = GoogleOAuth.makeCodeVerifier()
        XCTAssertEqual(verifier.count, 64)
        XCTAssertEqual(GoogleOAuth.base64URLEncoded(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(GoogleOAuth.base64URLDecoded("-_8"), Data([0xfb, 0xff]))
    }

    func testGmailParsing() {
        XCTAssertEqual(GmailAPI.parseMessageIdentifiers(Data(#"{"messages":[{"id":"1","threadId":"t"},{"id":"2"}]}"#.utf8)), ["1", "2"])
        XCTAssertEqual(GmailAPI.parseMessageIdentifiers(Data(#"{"resultSizeEstimate":0}"#.utf8)), [])
        let plain = GoogleOAuth.base64URLEncoded(Data("Salut Andrei,\nfactura e atașată.".utf8))
        let html = GoogleOAuth.base64URLEncoded(Data("<p>HTML</p>".utf8))
        let json = """
        {"id":"m1","labelIds":["INBOX","UNREAD"],"snippet":"Salut Andrei, factura &amp; tot","payload":{"mimeType":"multipart/alternative",
        "headers":[{"name":"From","value":"Ioana <ioana@lumen.ro>"},{"name":"Subject","value":"Factura septembrie"},{"name":"Date","value":"Tue, 29 Sep 2026 10:00:00 +0300"}],
        "parts":[{"mimeType":"text/html","body":{"data":"\(html)"}},{"mimeType":"text/plain","body":{"data":"\(plain)"}}]}}
        """
        let message = GmailAPI.parseMessage(Data(json.utf8))!
        XCTAssertEqual(message.subject, "Factura septembrie")
        XCTAssertEqual(message.bodyText, "Salut Andrei,\nfactura e atașată.")
        XCTAssertTrue(message.isUnread)
        XCTAssertEqual(message.snippet, "Salut Andrei, factura & tot")
        XCTAssertTrue(message.summaryLine.contains("UNREAD"))
        XCTAssertTrue(GmailAPI.readableMessage(message).hasPrefix("From: Ioana <ioana@lumen.ro>"))
        XCTAssertTrue(GmailAPI.searchURL(query: "is:unread newer_than:1d").absoluteString.contains("q=is:unread%20newer_than:1d"))
    }

    func testDriveParsingAndURLs() {
        let json = #"{"files":[{"id":"d1","name":"Contract Nordic","mimeType":"application/vnd.google-apps.document","modifiedTime":"2026-09-20T10:00:00Z","webViewLink":"https://docs.google.com/document/d/d1","owners":[{"displayName":"Alex"}]}]}"#
        let files = DriveAPI.parseFiles(Data(json.utf8))
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].owner, "Alex")
        XCTAssertTrue(files[0].summaryLine.contains("Google Doc"))
        let content = DriveAPI.contentURL(for: files[0])
        XCTAssertTrue(content.isExport)
        XCTAssertTrue(content.url.absoluteString.contains("/d1/export?mimeType=text/plain"))
        let pdf = DriveFile(identifier: "p", name: "a.pdf", mimeType: "application/pdf", modifiedTime: "", webViewLink: nil, owner: nil)
        XCTAssertFalse(DriveAPI.contentURL(for: pdf).isExport)
        let query = URLComponents(url: DriveAPI.searchURL(query: "Andrei's"), resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
        XCTAssertEqual(query, "(name contains 'Andrei\\'s' or fullText contains 'Andrei\\'s') and trashed = false")
    }

    func testEntitiesAndTools() {
        XCTAssertEqual(HTMLTextExtractor.decodeEntities("a &amp;lt; b &#39;c&#x219;"), "a &lt; b 'cș")
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "1", name: "search_gmail", argumentsJSON: #"{"query":"from:ioana","max_results":50}"#)),
                       .searchGmail(query: "from:ioana", maximumResults: 25))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "2", name: "search_files", argumentsJSON: #"{"query":"contract"}"#)),
                       .searchFiles(query: "contract", kind: "any"))
        XCTAssertEqual(ScreenAction.openFile(path: "/a").isReadOnly, false)
        XCTAssertEqual(ScreenAction.readDriveFile(identifier: "x").needsNoScreen, true)
    }
}
