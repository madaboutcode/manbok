import XCTest
@testable import UpilAppaCore

final class RecordingSessionTests: XCTestCase {
    func testAppendSilenceAddsGapBytes() {
        let session = RecordingSession()
        session.append(Data(count: 64))
        XCTAssertEqual(session.filledBytes, 64)

        session.appendSilence(seconds: AudioFormat.sessionGapSeconds)
        XCTAssertEqual(session.filledBytes, 64 + AudioFormat.sessionGapBytes)
    }

    func testAppendSilenceZeroSecondsIsNoOp() {
        let session = RecordingSession()
        session.append(Data(count: 10))
        session.appendSilence(seconds: 0)
        XCTAssertEqual(session.filledBytes, 10)
    }

    func testListAndDumpSessionsByGap() {
        let session = RecordingSession()
        session.append(Data(repeating: 0x11, count: 800))
        session.appendSilence(seconds: AudioFormat.sessionGapSeconds)
        session.append(Data(repeating: 0x22, count: 400))

        let list = session.listSessions()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].audioBytes, 800)
        XCTAssertFalse(list[0].isOpen)
        XCTAssertEqual(list[1].audioBytes, 400)
        XCTAssertTrue(list[1].isOpen)

        let first = session.snapshotForSession(id: 1)
        XCTAssertEqual(first?.count, 800)
        let second = session.snapshotForSession(id: 2)
        XCTAssertEqual(second?.count, 400)

        let full = session.snapshotForDump(minutes: nil)
        XCTAssertEqual(full.count, 800 + 400)
        XCTAssertFalse(containsSessionGapMarker(full))
        XCTAssertFalse(containsSessionGapMarker(first ?? Data()))
    }

    private func containsSessionGapMarker(_ pcm: Data) -> Bool {
        let gap = AudioFormat.sessionGapBytes
        guard pcm.count >= gap else { return false }
        for offset in 0 ... (pcm.count - gap) {
            if SessionCatalog.isSessionGap(at: offset, in: pcm, byteCount: gap) {
                return true
            }
        }
        return false
    }

    func testSessionTableFormattingUsesModernRuledList() {
        // Realistic-ish summaries (newest last)
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

        // Show the human what it looks like (appears in test log)
        print("\n=== dump --list (modern ruled) ===\n\(output)\n=== end ===\n")

        // Modern TUI visual: header rule using drawing char, no enclosing box.
        XCTAssertTrue(output.contains("━"), "should use unicode rule line (━ heavy for modern TUI header)")
        XCTAssertFalse(output.contains("┌") || output.contains("│"), "no box-drawing grid; modern ruled list only")
        XCTAssertTrue(output.contains("#"), "header should include #")
        XCTAssertTrue(output.contains("dur"), "header should include dur")
        XCTAssertTrue(output.contains("ended"), "header should have 'ended' column")
        XCTAssertTrue(output.contains("started"), "header should have 'started' column")
        XCTAssertTrue(output.contains("app"), "header should have app column")

        // Compact relative times (no "ago" inside cells; rule provides separation)
        XCTAssertTrue(output.contains("1m"), "should show compact '1m'")
        XCTAssertTrue(output.contains("15s"), "should show compact seconds")

        // Open session shows "open" not a time
        XCTAssertTrue(output.contains("open"), "open session should render 'open'")

        // Alignment: data values for metric cols are right-aligned within their col width.
        // We at least ensure the rule segments exist under the headers and values sit above them.
        XCTAssertTrue(output.contains("  #  "), "indented, header # present with spacing")
    }
}