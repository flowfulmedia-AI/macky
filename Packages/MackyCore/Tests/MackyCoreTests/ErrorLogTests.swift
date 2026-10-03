import XCTest
@testable import MackyCore

final class ErrorLogTests: XCTestCase {
    func testNewestFirstAndRepeatsWithinAMinuteKeptOnce() {
        var log = ErrorLog()
        let start = Date(timeIntervalSince1970: 1_000_000)
        log.add(ErrorLogEntry(date: start, source: "Agent", message: "A"))
        log.add(ErrorLogEntry(date: start.addingTimeInterval(10), source: "Agent", message: "A"))
        log.add(ErrorLogEntry(date: start.addingTimeInterval(20), source: "Email", message: "B"))
        XCTAssertEqual(log.entries.map(\.message), ["B", "A"])
        log.add(ErrorLogEntry(date: start.addingTimeInterval(200), source: "Email", message: "B"))
        XCTAssertEqual(log.entries.count, 3)
    }

    func testCapsTheNumberOfEntries() {
        var log = ErrorLog()
        for index in 0..<(ErrorLog.maximumEntries + 5) {
            log.add(ErrorLogEntry(date: Date(timeIntervalSince1970: Double(index) * 100), source: "x", message: "\(index)"))
        }
        XCTAssertEqual(log.entries.count, ErrorLog.maximumEntries)
        XCTAssertEqual(log.entries.first?.message, "\(ErrorLog.maximumEntries + 4)")
    }

    func testCrashReportSummary() throws {
        let header = #"{"app_name":"Macky","timestamp":"2026-10-03 07:00:12.00 +0300","name":"Macky"}"#
        let body = """
        {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
         "termination":{"indicator":"Trace/BPT trap: 5"},
         "asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},
         "faultingThread":0,
         "usedImages":[{"name":"libswiftCore.dylib"},{"name":"Macky"}],
         "threads":[{"triggered":true,"frames":[
            {"imageIndex":0,"symbol":"_assertionFailure"},
            {"imageIndex":1,"symbol":"AgentStore.produce(_:)","sourceFile":"AgentStore.swift","sourceLine":180},
            {"imageIndex":1,"imageOffset":255}]}]}
        """
        let summary = try XCTUnwrap(CrashReportParser.summary(of: header + "\n" + body))
        XCTAssertEqual(summary.reason, "EXC_BREAKPOINT · SIGTRAP · Trace/BPT trap: 5")
        XCTAssertNotNil(summary.date)
        XCTAssertTrue(summary.details.contains("Fatal error: Index out of range"))
        XCTAssertTrue(summary.details.contains("Macky  AgentStore.produce(_:)  (AgentStore.swift:180)"))
        XCTAssertTrue(summary.details.contains("Macky  0xff"))
    }

    func testNotACrashReport() {
        XCTAssertNil(CrashReportParser.summary(of: "hello"))
    }
}
