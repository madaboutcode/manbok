import Foundation

// MARK: - CONTRACT (SessionCatalog)
//
// GUARANTEES
// - Splits chronological PCM on exact session-gap markers (zero runs of sessionGapBytes).
// - Returns audio ranges in order; trailing audio without a following gap is one session (may be open).
// - `pcmWithoutSessionGaps` / `trimSessionGapPadding` omit gap markers from dump exports.
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
    /// Human-readable name of the app(s) that triggered this session (e.g. "Zoom", "FaceTime, OBS").
    public let appName: String?

    public init(
        id: Int,
        audioBytes: Int,
        durationSeconds: Double,
        startedSecondsAgo: TimeInterval,
        endedSecondsAgo: TimeInterval?,
        isOpen: Bool,
        appName: String? = nil
    ) {
        self.id = id
        self.audioBytes = audioBytes
        self.durationSeconds = durationSeconds
        self.startedSecondsAgo = startedSecondsAgo
        self.endedSecondsAgo = endedSecondsAgo
        self.isOpen = isOpen
        self.appName = appName
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

    /// PCM for WAV export: all non-gap regions concatenated (no 5s markers between sessions).
    public static func pcmWithoutSessionGaps(
        in pcm: Data,
        gapBytes: Int = AudioFormat.sessionGapBytes
    ) -> Data {
        let ranges = audioRanges(in: pcm, gapBytes: gapBytes)
        guard !ranges.isEmpty else { return pcm }
        return ranges.reduce(into: Data()) { exported, range in
            exported.append(pcm.subdata(in: range))
        }
    }

    /// Strips leading/trailing session-gap markers from one session slice (dump safety net).
    public static func trimSessionGapPadding(
        in pcm: Data,
        gapBytes: Int = AudioFormat.sessionGapBytes
    ) -> Data {
        guard gapBytes > 0, !pcm.isEmpty else { return pcm }
        var start = 0
        var end = pcm.count
        while start + gapBytes <= end,
              isSessionGap(at: start, in: pcm, byteCount: gapBytes) {
            start += gapBytes
        }
        while end - gapBytes >= start,
              isSessionGap(at: end - gapBytes, in: pcm, byteCount: gapBytes) {
            end -= gapBytes
        }
        guard start < end else { return Data() }
        return pcm.subdata(in: start ..< end)
    }

    public static func isSessionGap(at offset: Int, in pcm: Data, byteCount: Int) -> Bool {
        guard byteCount > 0, offset >= 0, offset + byteCount <= pcm.count else { return false }
        return pcm[offset ..< offset + byteCount].allSatisfy { $0 == 0 }
    }
}