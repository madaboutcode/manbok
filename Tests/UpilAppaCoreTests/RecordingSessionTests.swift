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
}