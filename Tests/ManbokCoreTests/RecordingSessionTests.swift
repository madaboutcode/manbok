import XCTest
@testable import ManbokCore

final class RecordingSessionTests: XCTestCase {
    func testCloseSessionWritesNoExtraBytes() {
        let session = RecordingSession()
        session.append(Data(repeating: 0xAA, count: 64))
        XCTAssertEqual(session.filledBytes, 64)

        session.closeSession()
        XCTAssertEqual(session.filledBytes, 64, "closeSession must not write any bytes to the ring")
    }

    func testListAndDumpSessions() {
        let session = RecordingSession()
        session.append(Data(repeating: 0x11, count: 800))
        session.closeSession()
        session.append(Data(repeating: 0x22, count: 400))

        let list = session.listSessions()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].audioBytes, 800)
        XCTAssertFalse(list[0].isOpen)
        XCTAssertEqual(list[1].audioBytes, 400)
        XCTAssertTrue(list[1].isOpen)

        let first = session.snapshotForSession(id: 1)
        XCTAssertEqual(first?.count, 800)
        XCTAssertEqual(first, Data(repeating: 0x11, count: 800))
        let second = session.snapshotForSession(id: 2)
        XCTAssertEqual(second?.count, 400)
        XCTAssertEqual(second, Data(repeating: 0x22, count: 400))

        let full = session.snapshotForDump(minutes: nil)
        XCTAssertEqual(full.count, 800 + 400)
    }

    func testExpiredSessionsDropFromList() {
        let capacity = 1000
        let session = RecordingSession(ringCapacity: capacity)

        // Session 1: 400 bytes
        session.append(Data(repeating: 0x11, count: 400))
        session.closeSession(appName: "App1")

        // Session 2: 400 bytes
        session.append(Data(repeating: 0x22, count: 400))
        session.closeSession(appName: "App2")

        XCTAssertEqual(session.listSessions().count, 2)

        // Session 3: 400 bytes — pushes ring past capacity, session 1 overwritten
        session.append(Data(repeating: 0x33, count: 400))
        session.closeSession(appName: "App3")

        let list = session.listSessions()
        XCTAssertEqual(list.count, 2, "session 1 should be expired")
        XCTAssertEqual(list[0].appName, "App2")
        XCTAssertEqual(list[1].appName, "App3")
    }

    func testPartiallyOverwrittenSessionIsDiscarded() {
        let capacity = 1000
        let session = RecordingSession(ringCapacity: capacity)

        // Session 1: 600 bytes
        session.append(Data(repeating: 0x11, count: 600))
        session.closeSession()

        // Write 500 more bytes — overwrites first 100 bytes of session 1
        session.append(Data(repeating: 0x22, count: 500))

        let list = session.listSessions()
        XCTAssertEqual(list.count, 1, "partially overwritten session should be discarded entirely")
        XCTAssertEqual(list[0].audioBytes, 500)
    }

    func testSnapshotForExpiredSessionReturnsNil() {
        let capacity = 1000
        let session = RecordingSession(ringCapacity: capacity)

        session.append(Data(repeating: 0x11, count: 400))
        session.closeSession()

        // Overwrite session 1 entirely; id=1 maps to the open session after expiry
        session.append(Data(repeating: 0x22, count: 1000))
        session.closeSession()

        // After expiry: closedSessions = [session2 (1000 bytes)]; id=1 → session2
        // id=2 is out of range — no such session exists
        XCTAssertNil(session.snapshotForSession(id: 2))
        // And confirm id=1 (session2) is readable
        XCTAssertNotNil(session.snapshotForSession(id: 1))
    }

    func testSessionAppNamePreserved() {
        let session = RecordingSession()
        session.append(Data(repeating: 0xAB, count: 100))
        session.closeSession(appName: "Zoom")

        let list = session.listSessions()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].appName, "Zoom")
    }

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

    func testOpenSessionLongerThanRingClampsToCap() {
        let capacity = 1000
        let session = RecordingSession(ringCapacity: capacity)
        session.append(Data(repeating: 0xAA, count: 1500))

        let list = session.listSessions()
        XCTAssertEqual(list.count, 1)
        XCTAssertLessThanOrEqual(list[0].audioBytes, capacity, "reported bytes must not exceed ring capacity")

        let snap = session.snapshotForSession(id: 1)
        XCTAssertNotNil(snap, "visible session must be snapshotable")
        XCTAssertEqual(snap?.count, list[0].audioBytes, "snapshot size must match listed size")
    }

    func testCloseSessionWithNoOpenIsNoOp() {
        let session = RecordingSession()
        session.closeSession()
        XCTAssertEqual(session.listSessions().count, 0)
        XCTAssertEqual(session.filledBytes, 0)
    }
}
