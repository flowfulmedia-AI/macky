import XCTest
@testable import MackyCore

final class MeetingTests: XCTestCase {
    func testZoomRequests() {
        XCTAssertEqual(ZoomAPI.tokenURL(accountIdentifier: "acc1").absoluteString, "https://zoom.us/oauth/token?grant_type=account_credentials&account_id=acc1")
        XCTAssertEqual(ZoomAPI.basicAuthorization(clientIdentifier: "id", clientSecret: "secret"), "Basic aWQ6c2VjcmV0")
        let url = ZoomAPI.recordingsURL(userIdentifier: "me", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 86_400 * 3)).absoluteString
        XCTAssertEqual(url, "https://api.zoom.us/v2/users/me/recordings?from=1970-01-01&to=1970-01-04&page_size=30")
    }

    func testParseRecordings() {
        let json = """
        {"next_page_token":"","meetings":[{"uuid":"abc==","topic":"Call Nordic","start_time":"2026-09-30T08:00:00Z","duration":45,
        "recording_files":[
          {"id":"f1","file_type":"MP4","recording_type":"shared_screen_with_speaker_view","download_url":"https://zoom.us/rec/1","status":"completed","file_size":900},
          {"id":"f2","file_type":"M4A","recording_type":"audio_only","download_url":"https://zoom.us/rec/2","status":"completed","file_size":300},
          {"id":"f3","file_type":"TRANSCRIPT","recording_type":"audio_transcript","download_url":"https://zoom.us/rec/3","status":"completed","file_size":10}]}]}
        """
        let result = ZoomAPI.parseRecordings(Data(json.utf8))
        XCTAssertNil(result.nextPageToken)
        let meeting = result.meetings[0]
        XCTAssertEqual(meeting.topic, "Call Nordic")
        XCTAssertEqual(meeting.durationMinutes, 45)
        XCTAssertEqual(meeting.transcriptFile?.identifier, "f3")
        XCTAssertEqual(meeting.audioFile?.identifier, "f2")
        XCTAssertFalse(meeting.isStillProcessing)
        XCTAssertNotNil(meeting.startTime)
    }

    func testWebVTT() {
        let vtt = "WEBVTT\r\n\r\n1\r\n00:00:01.000 --> 00:00:04.000\r\nAna Pop: Bună, începem?\r\n\r\n2\r\n00:00:04.500 --> 00:00:06.000\r\nAna Pop: Avem trei puncte.\r\n\r\n3\r\n01:02:03.000 --> 01:02:05.000\r\nAndrei: Da.\r\n"
        let lines = TranscriptFormatter.parseWebVTT(vtt)
        XCTAssertEqual(lines, [
            TranscriptLine(startSeconds: 1, speaker: "Ana Pop", text: "Bună, începem? Avem trei puncte."),
            TranscriptLine(startSeconds: 3723, speaker: "Andrei", text: "Da.")
        ])
        XCTAssertEqual(TranscriptFormatter.plainText(lines), "[00:01] Ana Pop: Bună, începem? Avem trei puncte.\n[1:02:03] Andrei: Da.")
    }

    func testNotesParsingAndDocument() {
        let response = #"```json {"title":"Lansare Nordic","participants":["Ana","Andrei"],"summary":"Am stabilit lansarea.","decisions":["Lansăm pe 15 octombrie"],"action_items":[{"owner":"Andrei","task":"Trimite contractul","due":"vineri"},{"owner":null,"task":"Pregătește slide-urile","due":null}]} ```"#
        let notes = MeetingNotesBuilder.parse(response, fallbackTitle: "x")
        XCTAssertEqual(notes.title, "Lansare Nordic")
        XCTAssertEqual(notes.actionItems.count, 2)
        XCTAssertNil(notes.actionItems[1].owner)
        let html = MeetingNotesBuilder.html(notes: notes, topic: "Call <Nordic>", date: "30 sept", durationMinutes: 45,
                                            transcriptLines: [TranscriptLine(startSeconds: 1, speaker: "Ana", text: "Salut & bun venit")])
        XCTAssertTrue(html.contains("<h2>Acțiuni</h2><ul><li><b>Andrei:</b> Trimite contractul <i>(vineri)</i></li>"))
        XCTAssertTrue(html.contains("Call &lt;Nordic&gt;"))
        XCTAssertTrue(html.contains("Salut &amp; bun venit"))
        XCTAssertTrue(MeetingNotesBuilder.markdown(notes: notes, topic: "t", date: "d", transcriptLines: []).contains("- **Andrei:** Trimite contractul (vineri)"))
        XCTAssertEqual(MeetingNotesBuilder.parse("Rezumat simplu.", fallbackTitle: "Meeting").summary, "Rezumat simplu.")
        let long = String(repeating: "a", count: MeetingNotesBuilder.maximumTranscriptCharacters + 10)
        XCTAssertTrue(MeetingNotesBuilder.messages(topic: "t", date: "d", transcript: long)[1].plainText.contains("omitted"))
    }

    func testDriveMultipart() {
        let upload = DriveUpload.multipartBody(name: "Notițe", targetMimeType: "application/vnd.google-apps.document", parentFolderIdentifier: "folder1",
                                               content: Data("<p>x</p>".utf8), contentMimeType: "text/html", boundary: "B")
        let text = String(decoding: upload.body, as: UTF8.self)
        XCTAssertEqual(upload.contentType, "multipart/related; boundary=B")
        XCTAssertTrue(text.hasPrefix("--B\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{"))
        XCTAssertTrue(text.contains(#""parents":["folder1"]"#))
        XCTAssertTrue(text.hasSuffix("\r\n--B\r\nContent-Type: text/html\r\n\r\n<p>x</p>\r\n--B--\r\n"))
        XCTAssertEqual(DriveUpload.parseCreatedFile(Data(#"{"id":"d1","webViewLink":"https://docs.google.com/d1"}"#.utf8))?.link, "https://docs.google.com/d1")
    }

    func testTaskCapture() {
        XCTAssertTrue(TaskCaptureIntent.matches("Fă task din asta"))
        XCTAssertTrue(TaskCaptureIntent.matches("Macky, pune asta ca task, te rog"))
        XCTAssertTrue(TaskCaptureIntent.matches("fă-mi un task din asta pentru mâine"))
        XCTAssertFalse(TaskCaptureIntent.matches("ce taskuri am azi?"))
        XCTAssertTrue(TaskCaptureIntent.instruction(taskAppNames: ["Flowts"]).contains("in Flowts"))
        XCTAssertTrue(TaskCaptureIntent.instruction(taskAppNames: []).contains("create_reminder"))
        let context = FrontmostApplicationContext(applicationName: "Google Chrome", windowTitle: "Inbox", pageURL: "https://mail.google.com/mail/u/0/#inbox/abc")
        XCTAssertTrue(MackyPrompt.userMessageText(question: "q", screenshots: [], frontmostApplication: context, coordinateConvention: .imagePixels)
            .contains("Open page: https://mail.google.com/mail/u/0/#inbox/abc"))
    }
}
