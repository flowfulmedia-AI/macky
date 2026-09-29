import XCTest
@testable import MackyCore

final class SystemCommandTests: XCTestCase {
    func testVolume() {
        XCTAssertEqual(SystemCommandMatcher.match("Pune volumul la 30"), .setVolume(percent: 30))
        XCTAssertEqual(SystemCommandMatcher.match("volumul mai tare"), .volumeUp)
        XCTAssertEqual(SystemCommandMatcher.match("Dă mai încet."), .volumeDown)
        XCTAssertEqual(SystemCommandMatcher.match("pune muzica mai tare"), .volumeUp)
        XCTAssertEqual(SystemCommandMatcher.match("oprește sunetul"), .mute)
        XCTAssertEqual(SystemCommandMatcher.match("Volume 150"), .setVolume(percent: 100))
    }

    func testOtherSettings() {
        XCTAssertEqual(SystemCommandMatcher.match("pornește dark mode"), .darkMode(enabled: true))
        XCTAssertEqual(SystemCommandMatcher.match("oprește modul întunecat"), .darkMode(enabled: false))
        XCTAssertEqual(SystemCommandMatcher.match("luminozitatea mai mare"), .brightnessUp)
        XCTAssertEqual(SystemCommandMatcher.match("blochează ecranul"), .lockScreen)
        XCTAssertNil(SystemCommandMatcher.match("pune Numb de la Linkin Park"))
        XCTAssertNil(SystemCommandMatcher.match("ce e pe ecran?"))
    }

    func testToolArguments() {
        XCTAssertEqual(SystemCommand(toolArgumentsJSON: #"{"action":"set_volume","value":"40"}"#), .setVolume(percent: 40))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "a", name: "system_control", argumentsJSON: #"{"action":"lock_screen"}"#)), .system(.lockScreen))
    }

    func testWindowLayouts() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(WindowLayout.leftHalf.frame(in: visibleFrame), CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(WindowLayout.rightHalf.frame(in: visibleFrame), CGRect(x: 500, y: 0, width: 500, height: 800))
        XCTAssertEqual(WindowLayout.topHalf.frame(in: visibleFrame), CGRect(x: 0, y: 400, width: 1000, height: 400))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "w", name: "arrange_window", argumentsJSON: #"{"app":"Safari","layout":"left"}"#)),
                       .arrangeWindow(applicationName: "Safari", layout: .leftHalf))
    }
}

final class CalendarAndDateTests: XCTestCase {
    let bucharest = TimeZone(identifier: "Europe/Bucharest")!

    func testParsesLocalAndZonedDates() {
        let local = FlexibleDateParser.date(from: "2026-10-02T15:00:00", timeZone: bucharest)
        XCTAssertEqual(local?.timeIntervalSince1970, 1_790_942_400)
        XCTAssertEqual(FlexibleDateParser.date(from: "2026-10-02T12:00:00Z")?.timeIntervalSince1970, 1_790_942_400)
        XCTAssertEqual(FlexibleDateParser.date(from: "2026-10-02T15:00", timeZone: bucharest)?.timeIntervalSince1970, 1_790_942_400)
        XCTAssertNotNil(FlexibleDateParser.date(from: "2026-10-02", timeZone: bucharest))
        XCTAssertNil(FlexibleDateParser.date(from: "mâine"))
    }

    func testCreateEventDefaultsToOneHour() throws {
        let action = ScreenAction(toolCall: ChatToolCall(identifier: "e", name: "create_event",
                                                         argumentsJSON: #"{"title":"Dentist","start":"2026-10-02T15:00:00Z","location":" "}"#))
        guard case .createEvent(let request) = try XCTUnwrap(action) else { return XCTFail("wrong action") }
        XCTAssertEqual(request.title, "Dentist")
        XCTAssertEqual(request.endDate.timeIntervalSince(request.startDate), 3600)
        XCTAssertNil(request.location)
        XCTAssertFalse(action!.isReadOnly)
    }

    func testRemindersNotesAndBackgroundTasks() {
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "r", name: "create_reminder", argumentsJSON: #"{"title":"Sună la bancă"}"#)),
                       .createReminder(title: "Sună la bancă", dueDate: nil, notes: nil))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "l", name: "list_reminders", argumentsJSON: "{}")), .listReminders(limit: 20))
        XCTAssertTrue(ScreenAction.listReminders(limit: 5).isReadOnly)
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "n", name: "create_note", argumentsJSON: #"{"title":"Idee","body":"text"}"#)),
                       .createNote(title: "Idee", body: "text"))
        XCTAssertEqual(ScreenAction(toolCall: ChatToolCall(identifier: "b", name: "start_background_task", argumentsJSON: #"{"goal":"caută microfoane"}"#)),
                       .startBackgroundTask(goal: "caută microfoane"))
        XCTAssertNil(ScreenAction(toolCall: ChatToolCall(identifier: "x", name: "web_search", argumentsJSON: #"{"query":"a"}"#)))
    }

    func testDateContextMentionsTimeZone() {
        let context = FlexibleDateParser.currentDateContext(now: Date(timeIntervalSince1970: 1_790_942_400), timeZone: bucharest)
        XCTAssertEqual(context, "Current local date and time: Friday 2026-10-02T15:00 (time zone Europe/Bucharest).")
    }
}

final class TextExtractionTests: XCTestCase {
    func testHTMLToText() {
        let html = "<html><head><title>x</title><style>p{}</style></head><body><nav>menu</nav><h1>Titlu</h1><p>Primul &amp; al doilea</p><script>alert(1)</script><p>Ultimul</p></body></html>"
        XCTAssertEqual(HTMLTextExtractor.readableText(fromHTML: html), "Titlu\nPrimul & al doilea\nUltimul")
        XCTAssertTrue(HTMLTextExtractor.readableText(fromHTML: String(repeating: "a", count: 50), maximumCharacters: 10).hasSuffix("[…]"))
    }

    func testFileNames() {
        XCTAssertEqual(HTMLTextExtractor.sanitizedFileName("../../etc/passwd"), "passwd.md")
        XCTAssertEqual(HTMLTextExtractor.sanitizedFileName("raport.txt"), "raport.txt")
        XCTAssertEqual(HTMLTextExtractor.sanitizedFileName("..."), "rezultat.md")
    }
}

final class SpeechEndpointDetectorTests: XCTestCase {
    func testDetectsEndOfSpeechAndSilentTail() {
        var detector = SpeechEndpointDetector()
        // 0.5 s of quiet, 1 s of speech, then 0.4 s of quiet, in 0.1 s chunks at 16 kHz.
        for _ in 0..<5 { detector.append(chunkLevel: 0.002, sampleCount: 1600) }
        XCTAssertFalse(detector.hasSpeechEnded(minimumPause: 0.3, sampleRate: 16_000), "silence before speech is not an end")
        for _ in 0..<10 { detector.append(chunkLevel: 0.1, sampleCount: 1600) }
        XCTAssertFalse(detector.hasSpeechEnded(minimumPause: 0.3, sampleRate: 16_000))
        for _ in 0..<4 { detector.append(chunkLevel: 0.004, sampleCount: 1600) }
        XCTAssertTrue(detector.hasSpeechEnded(minimumPause: 0.3, sampleRate: 16_000))

        let snapshotSampleCount = detector.totalSampleCount
        detector.append(chunkLevel: 0.003, sampleCount: 1600)
        XCTAssertTrue(detector.isSilentAfter(sampleIndex: snapshotSampleCount), "only silence was added after the snapshot")
        detector.append(chunkLevel: 0.09, sampleCount: 1600)
        XCTAssertFalse(detector.isSilentAfter(sampleIndex: snapshotSampleCount), "the user spoke again")
    }
}

final class BackgroundTaskTriggerTests: XCTestCase {
    func testTriggers() {
        XCTAssertEqual(BackgroundTaskTrigger.goal(from: "Agent, caută cele mai bune microfoane sub 500 de lei."), "caută cele mai bune microfoane sub 500 de lei")
        XCTAssertEqual(BackgroundTaskTrigger.goal(from: "În fundal: fă-mi un rezumat despre AI în 2026"), "fă-mi un rezumat despre AI în 2026")
        XCTAssertEqual(BackgroundTaskTrigger.goal(from: "compară iPhone și Pixel în fundal."), "compară iPhone și Pixel")
        XCTAssertNil(BackgroundTaskTrigger.goal(from: "agent"))
        XCTAssertNil(BackgroundTaskTrigger.goal(from: "unde e butonul de export"))
        XCTAssertNil(BackgroundTaskTrigger.goal(from: "agentia de turism e deschisa?"))
    }
}
