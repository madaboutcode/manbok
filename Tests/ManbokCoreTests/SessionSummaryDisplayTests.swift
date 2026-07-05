import XCTest
@testable import ManbokCore

// Moved out of the deleted RecordingSessionTests.swift (SessionRegistry replaces
// RecordingSession) — this test exercises SessionSummary.table's static formatting only, with
// hand-built SessionSummary values; it never depended on RecordingSession and guards unchanged
// CLI/IPC display behavior.
final class SessionSummaryDisplayTests: XCTestCase {
    func testSessionTableFormattingUsesModernRuledList() {
        let s1 = SessionSummary(
            id: 1,
            audioBytes: 241_000,
            durationSeconds: 15.1,
            startedSecondsAgo: 75,
            endedSecondsAgo: 60,
            isOpen: false,
            appName: "Extension"
        )
        let s2 = SessionSummary(
            id: 2,
            audioBytes: 144_000,
            durationSeconds: 9.0,
            startedSecondsAgo: 15,
            endedSecondsAgo: 6,
            isOpen: false,
            appName: "Pipit"
        )
        let open = SessionSummary(
            id: 3,
            audioBytes: 32_000,
            durationSeconds: 2.0,
            startedSecondsAgo: 2,
            endedSecondsAgo: nil,
            isOpen: true,
            appName: "Zoom"
        )

        let output = SessionSummary.table([s1, s2, open])
        print("\n=== dump --list (modern ruled) ===\n\(output)\n=== end ===\n")

        XCTAssertTrue(output.contains("━"), "should use unicode rule line")
        XCTAssertFalse(output.contains("┌") || output.contains("│"), "no box-drawing grid")
        XCTAssertTrue(output.contains("#"), "header should include #")
        XCTAssertTrue(output.contains("dur"), "header should include dur")
        XCTAssertTrue(output.contains("ended"), "header should have 'ended' column")
        XCTAssertTrue(output.contains("started"), "header should have 'started' column")
        XCTAssertTrue(output.contains("app"), "header should have app column")
        XCTAssertTrue(output.contains("1m"), "should show compact '1m'")
        XCTAssertTrue(output.contains("15s"), "should show compact seconds")
        XCTAssertTrue(output.contains("open"), "open session should render 'open'")
        XCTAssertTrue(output.contains("  #  "), "indented, header # present with spacing")
    }
}
