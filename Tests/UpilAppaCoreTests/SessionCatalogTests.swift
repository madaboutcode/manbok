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

}