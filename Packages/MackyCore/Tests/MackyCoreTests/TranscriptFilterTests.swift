@testable import MackyCore
import XCTest

final class TranscriptFilterTests: XCTestCase {
    func testPhantomPhrasesFromSilence() {
        XCTAssertTrue(TranscriptFilter.isPhantom("Să vă mulțumim de vizionare!"))
        XCTAssertTrue(TranscriptFilter.isPhantom("Vă mulțumim pentru vizionare. Abonați-vă!"))
        XCTAssertTrue(TranscriptFilter.isPhantom("Subtitrare realizată de ..."))
        XCTAssertTrue(TranscriptFilter.isPhantom("Thanks for watching!"))
        XCTAssertTrue(TranscriptFilter.isPhantom("  ...  "))
    }

    func testRealRequestsPass() {
        XCTAssertFalse(TranscriptFilter.isPhantom("Trimite-i Mariei pe WhatsApp că întârzii"))
        XCTAssertFalse(TranscriptFilter.isPhantom("Mulțumesc, acum deschide Spotify"))
        XCTAssertFalse(TranscriptFilter.isPhantom("Ce am în calendar azi?"))
    }
}
