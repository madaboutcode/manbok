import XCTest
@testable import ManbokCore

final class BufferPolicyTests: XCTestCase {
    // MARK: - Capacity math

    func testCapacityBytesForEachPreset() {
        XCTAssertEqual(BufferPolicy.capacityBytes(for: .min5), AudioFormat.bytesPerMinute * 5)
        XCTAssertEqual(BufferPolicy.capacityBytes(for: .min10), AudioFormat.bytesPerMinute * 10)
        XCTAssertEqual(BufferPolicy.capacityBytes(for: .min30), AudioFormat.bytesPerMinute * 30)
        XCTAssertEqual(BufferPolicy.capacityBytes(for: .min60), AudioFormat.bytesPerMinute * 60)
        XCTAssertEqual(BufferPolicy.capacityBytes(for: .min120), AudioFormat.bytesPerMinute * 120)

        // Exact byte values, tying the math to the canonical 16kHz mono s16le format.
        XCTAssertEqual(BufferPolicy.capacityBytes(for: .min10), 19_200_000)
        XCTAssertEqual(BufferPolicy.capacityBytes(for: .min30), 57_600_000)
    }

    func testDefaultPresetIsMin10() {
        XCTAssertEqual(BufferPolicy.Preset.default, .min10)
    }

    // MARK: - Memory cost strings

    func testMemoryCostStrings() {
        XCTAssertEqual(BufferPolicy.memoryCost(for: .min5), "~10 MB")
        XCTAssertEqual(BufferPolicy.memoryCost(for: .min10), "~19 MB")
        XCTAssertEqual(BufferPolicy.memoryCost(for: .min30), "~58 MB")
        XCTAssertEqual(BufferPolicy.memoryCost(for: .min60), "~115 MB")
        XCTAssertEqual(BufferPolicy.memoryCost(for: .min120), "~230 MB")
    }

    // MARK: - Sessions lost

    func testGrowingRingLosesNoSessions() {
        let sessions = [
            BufferPolicy.SessionByteRange(startTotalOffset: 0, audioBytes: 1_000),
            BufferPolicy.SessionByteRange(startTotalOffset: 5_000, audioBytes: 1_000),
        ]
        let lost = BufferPolicy.sessionsLost(
            currentSessions: sessions,
            targetPreset: .min120,
            ringTotalWritten: 6_000
        )
        XCTAssertEqual(lost, 0)
    }

    func testShrinkingRingCountsFullyExpiredSessions() {
        // 10-minute ring's worth of bytes already written; shrinking to 5 minutes should
        // drop any session whose bytes are entirely older than the new 5-minute window.
        let bytesPerMinute = Int64(AudioFormat.bytesPerMinute)
        let ringTotalWritten = bytesPerMinute * 10
        let newOldestValidOffset = ringTotalWritten - bytesPerMinute * 5 // = 5 minutes in

        let longAgoSession = BufferPolicy.SessionByteRange(
            startTotalOffset: 0,
            audioBytes: Int(bytesPerMinute) // ends at 1 min — fully before the new cutoff
        )
        let recentSession = BufferPolicy.SessionByteRange(
            startTotalOffset: newOldestValidOffset + bytesPerMinute,
            audioBytes: Int(bytesPerMinute) // starts after the cutoff — survives fully
        )

        let lost = BufferPolicy.sessionsLost(
            currentSessions: [longAgoSession, recentSession],
            targetPreset: .min5,
            ringTotalWritten: ringTotalWritten
        )
        XCTAssertEqual(lost, 1)
    }

    func testSessionEndingExactlyAtNewWindowEdgeIsLost() {
        // A session whose last byte is exactly the new oldest-valid-offset has zero bytes
        // remaining in the shrunk window — it counts as lost.
        let bytesPerMinute = Int64(AudioFormat.bytesPerMinute)
        let ringTotalWritten = bytesPerMinute * 10
        let newOldestValidOffset = ringTotalWritten - bytesPerMinute * 5

        let atEdge = BufferPolicy.SessionByteRange(
            startTotalOffset: 0,
            audioBytes: Int(newOldestValidOffset)
        )
        XCTAssertEqual(
            BufferPolicy.sessionsLost(
                currentSessions: [atEdge],
                targetPreset: .min5,
                ringTotalWritten: ringTotalWritten
            ),
            1
        )
    }

    func testSessionWithOneByteAfterNewWindowEdgeSurvives() {
        // One byte past the cutoff means the session is not fully expired.
        let bytesPerMinute = Int64(AudioFormat.bytesPerMinute)
        let ringTotalWritten = bytesPerMinute * 10
        let newOldestValidOffset = ringTotalWritten - bytesPerMinute * 5

        let justPastEdge = BufferPolicy.SessionByteRange(
            startTotalOffset: 0,
            audioBytes: Int(newOldestValidOffset) + 1
        )
        XCTAssertEqual(
            BufferPolicy.sessionsLost(
                currentSessions: [justPastEdge],
                targetPreset: .min5,
                ringTotalWritten: ringTotalWritten
            ),
            0
        )
    }
}
