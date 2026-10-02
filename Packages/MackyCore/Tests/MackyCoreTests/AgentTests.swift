@testable import MackyCore
import XCTest

final class AgentTests: XCTestCase {
    func testDriveFolderIdentifier() {
        XCTAssertEqual(AgentKit.driveFolderIdentifier(from: "https://drive.google.com/drive/folders/1BeNGL9VFRKLUO9_g1-t7tL6wRlzjG1qC"),
                       "1BeNGL9VFRKLUO9_g1-t7tL6wRlzjG1qC")
        XCTAssertEqual(AgentKit.driveFolderIdentifier(from: "https://drive.google.com/drive/u/0/folders/1BeNGL9VFRKLUO9_g1-t7tL6wRlzjG1qC?usp=sharing"),
                       "1BeNGL9VFRKLUO9_g1-t7tL6wRlzjG1qC")
        XCTAssertEqual(AgentKit.driveFolderIdentifier(from: "1BeNGL9VFRKLUO9_g1-t7tL6wRlzjG1qC"), "1BeNGL9VFRKLUO9_g1-t7tL6wRlzjG1qC")
        XCTAssertEqual(AgentKit.driveFolderIdentifier(from: "https://drive.google.com/open?id=1AbcdefghijKLM"), "1AbcdefghijKLM")
        XCTAssertNil(AgentKit.driveFolderIdentifier(from: ""))
        XCTAssertNil(AgentKit.driveFolderIdentifier(from: "folderul meu"))
    }

    func testMissedScheduledRunHappensLaterThatDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        let agent = AgentDefinition(name: "Romeo", instructions: "x",
                                    schedule: RoutineSchedule(isEnabled: true, hour: 7, minute: 0, weekdays: RoutineSchedule.everyDay))
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 11, minute: 30))!
        XCTAssertTrue(agent.isDue(now: morning, calendar: calendar))
        var ran = agent
        ran.lastRunAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 11, minute: 31))!
        XCTAssertFalse(ran.isDue(now: morning.addingTimeInterval(3600), calendar: calendar))
        var paused = agent
        paused.isEnabled = false
        XCTAssertFalse(paused.isDue(now: morning, calendar: calendar))
        let onDemand = AgentDefinition(name: "x", instructions: "y")
        XCTAssertFalse(onDemand.isDue(now: morning, calendar: calendar))
        XCTAssertEqual(onDemand.modeDescription, "La cerere")
    }

    func testRunsAreCapped() {
        var agent = AgentDefinition(name: "x", instructions: "y")
        for _ in 0..<40 { agent.record(AgentRun()) }
        XCTAssertEqual(agent.runs.count, AgentDefinition.maximumKeptRuns)
    }

    func testMarkdownToHTML() {
        let html = MarkdownHTML.body("""
        # Romeo
        ## ADN Financiar
        1. **Unghi**: banii & destinul
        2. Al doilea
        - hook <unu>
        Text *cursiv*
        """)
        XCTAssertTrue(html.contains("<h1>Romeo</h1>"))
        XCTAssertTrue(html.contains("<h2>ADN Financiar</h2>"))
        XCTAssertTrue(html.contains("<ol><li><b>Unghi</b>: banii &amp; destinul</li><li>Al doilea</li></ol>"))
        XCTAssertTrue(html.contains("<ul><li>hook &lt;unu&gt;</li></ul>"))
        XCTAssertTrue(html.contains("<p>Text <i>cursiv</i></p>"))
        XCTAssertEqual(MarkdownHTML.inline("2 * 3"), "2 * 3")
    }

    func testPromptMentionsSkillAndFreshIdeas() {
        let prompt = AgentKit.systemPrompt(agentName: "Romeo", skillName: "macky-romeo", skillText: "Reguli Meta", allowsWebResearch: false, writesDocument: true)
        XCTAssertTrue(prompt.contains("Reguli Meta"))
        XCTAssertTrue(prompt.contains("Google Doc"))
        let task = AgentKit.taskMessage(instructions: "10 unghiuri", extraRequest: nil, dateContext: "Azi", previousTitles: ["Romeo · 1 octombrie 2026"])
        XCTAssertTrue(task.contains("fresh ideas"))
        XCTAssertEqual(AgentKit.summary(of: "\n# Unghiuri pentru Romeo\nrest"), "Unghiuri pentru Romeo")
    }
}
