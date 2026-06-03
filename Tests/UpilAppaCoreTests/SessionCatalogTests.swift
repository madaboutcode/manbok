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

    func testPcmWithoutSessionGapsJoinsAudioOnly() {
        let gap = AudioFormat.sessionGapBytes
        var pcm = Data(repeating: 0x11, count: 1000)
        pcm.append(Data(count: gap))
        pcm.append(Data(repeating: 0x22, count: 500))

        let exported = SessionCatalog.pcmWithoutSessionGaps(in: pcm)
        XCTAssertEqual(exported.count, 1500)
        XCTAssertEqual(exported.prefix(1000), Data(repeating: 0x11, count: 1000))
        XCTAssertEqual(exported.suffix(500), Data(repeating: 0x22, count: 500))
    }

    func testTrimSessionGapPaddingStripsLeadingAndTrailing() {
        let gap = AudioFormat.sessionGapBytes
        var pcm = Data(count: gap)
        pcm.append(Data(repeating: 0x33, count: 200))
        pcm.append(Data(count: gap))

        let trimmed = SessionCatalog.trimSessionGapPadding(in: pcm)
        XCTAssertEqual(trimmed.count, 200)
        XCTAssertEqual(trimmed, Data(repeating: 0x33, count: 200))
    }
}