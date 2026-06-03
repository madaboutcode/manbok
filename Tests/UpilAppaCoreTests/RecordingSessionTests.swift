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
    }
}