import XCTest
@testable import UpilAppaCore

final class SessionCatalogTests: XCTestCase {
    func testAudioRangesSplitOnFiveSecondGap() {
        let gap = AudioFormat.sessionGapBytes
        var pcm = Data(repeating: 1, count: 1000)
        pcm.append(Data(count: gap))
        pcm.append(Data(repeating: 2, count: 2000))

        let ranges = SessionCatalog.audioRanges(in: pcm, gapBytes: gap)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 0 ..< 1000)
        XCTAssertEqual(ranges[1], 1000 + gap ..< pcm.count)
    }

    func testSessionsResponseRoundTrip() {
        let list = [
            SessionSummary(
                id: 1,
                audioBytes: 32_000,
                durationSeconds: 2.0,
                startedSecondsAgo: 600,
                endedSecondsAgo: 120,
                isOpen: false
            ),
            SessionSummary(
                id: 2,
                audioBytes: 16_000,
                durationSeconds: 1.0,
                startedSecondsAgo: 90,
                endedSecondsAgo: nil,
                isOpen: true
            ),
        ]
        let response = IPCResponse.sessions(list)
        guard case .sessions(let parsed) = IPCResponse.parse(line: response.line) else {
            XCTFail("expected sessions response")
            return
        }
        XCTAssertEqual(parsed, list)
    }
}