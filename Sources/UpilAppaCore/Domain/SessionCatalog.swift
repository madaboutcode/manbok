import Foundation

// MARK: - CONTRACT (SessionCatalog)
//
// GUARANTEES
// - Splits chronological PCM on exact session-gap markers (zero runs of sessionGapBytes).
// - Returns audio ranges in order; trailing audio without a following gap is one session (may be open).
//
// DOES NOT
// - Read the ring buffer directly.

/// One captured session slice in the ring (1-based id assigned at list time).
public struct SessionSummary: Sendable, Equatable {
    public let id: Int
    public let audioBytes: Int
    public let durationSeconds: Double
    /// Seconds before `now` that capture for this session began.
    public let startedSecondsAgo: TimeInterval
    /// Seconds before `now` the session ended (gap inserted); nil while still recording.
    public let endedSecondsAgo: TimeInterval?
    public let isOpen: Bool

    public init(
        id: Int,
        audioBytes: Int,
        durationSeconds: Double,
        startedSecondsAgo: TimeInterval,
        endedSecondsAgo: TimeInterval?,
        isOpen: Bool
    ) {
        self.id = id
        self.audioBytes = audioBytes
        self.durationSeconds = durationSeconds
        self.startedSecondsAgo = startedSecondsAgo
        self.endedSecondsAgo = endedSecondsAgo
        self.isOpen = isOpen
    }
}

public enum SessionCatalog {
    /// Finds non-gap audio regions in chronological PCM (newest ring snapshot).
    public static func audioRanges(
        in pcm: Data,
        gapBytes: Int = AudioFormat.sessionGapBytes
    ) -> [Range<Int>] {
        guard !pcm.isEmpty else { return [] }
        guard gapBytes > 0 else { return [0 ..< pcm.count] }

        var ranges: [Range<Int>] = []
        var index = 0

        while index < pcm.count {
            if isSessionGap(at: index, in: pcm, byteCount: gapBytes) {
                index += gapBytes
                continue
            }
            let start = index
            while index < pcm.count, !isSessionGap(at: index, in: pcm, byteCount: gapBytes) {
                index += 1
            }
            if start < index {
                ranges.append(start ..< index)
            }
        }

        return ranges
    }

    public static func isSessionGap(at offset: Int, in pcm: Data, byteCount: Int) -> Bool {
        guard byteCount > 0, offset >= 0, offset + byteCount <= pcm.count else { return false }
        return pcm[offset ..< offset + byteCount].allSatisfy { $0 == 0 }
    }
}