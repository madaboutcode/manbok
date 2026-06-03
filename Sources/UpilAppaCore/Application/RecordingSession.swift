import Foundation

// MARK: - CONTRACT: RecordingSession
//
// GUARANTEES:
// - Only mutates ring on capture callback path (serialized on internal queue).
// - appendSilence(seconds:) writes zero PCM for session markers (same queue as append).
// - Closed sessions recorded when a gap is appended; open session tracked until next gap.
// - snapshotForSession(id:) extracts one session using gap markers in chronological PCM.
// - snapshotForDump(minutes:) is consistent — no partial write visible.
//
// EXPECTS:
// - AudioCapturing delivers converted PCM only; ListenerService forwards append calls.
// - Session gaps use AudioFormat.sessionGapBytes (5s zeros).
//
// FAILURE BEHAVIOR:
// - Capture stop → session quiescent; ring contents preserved until process exit.
//
// DOES NOT:
// - Start/stop capture, write files, or encode WAV.

/// Owns the byte ring and exposes thread-safe append and dump snapshots.
public final class RecordingSession {
    private struct ClosedSession {
        let audioBytes: Int
        let startedAt: Date
        let endedAt: Date
    }

    private var ring = ByteRingBuffer()
    private var lastAppendAt: Date?
    private var closedSessions: [ClosedSession] = []
    private var openSessionStartedAt: Date?
    private var openSessionAudioBytes = 0
    private let queue = DispatchQueue(label: "ai.upil.appa.recording-session")

    public init() {}

    public var filledBytes: Int {
        queue.sync { ring.filledBytes }
    }

    /// Seconds since last PCM chunk arrived; `.infinity` if never.
    public var secondsSinceLastAppend: TimeInterval {
        queue.sync {
            guard let lastAppendAt else { return .infinity }
            return Date().timeIntervalSince(lastAppendAt)
        }
    }

    /// Appends PCM from the capture sink (serialized with snapshot reads).
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.sync {
            if openSessionStartedAt == nil {
                openSessionStartedAt = Date()
            }
            openSessionAudioBytes += data.count
            ring.write(data)
            lastAppendAt = Date()
        }
    }

    /// Appends digital silence (zero samples) for visual separation between sessions.
    public func appendSilence(seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let byteCount = Int(seconds * Double(AudioFormat.bytesPerSecond))
        guard byteCount > 0 else { return }
        queue.sync {
            closeOpenSession(endedAt: Date())
            ring.write(Data(count: byteCount))
            lastAppendAt = Date()
        }
    }

    /// Sessions in chronological order (1-based ids). Open session is last when present.
    public func listSessions(now: Date = Date()) -> [SessionSummary] {
        queue.sync {
            var summaries: [SessionSummary] = []
            var nextId = 1

            for closed in closedSessions {
                summaries.append(
                    SessionSummary(
                        id: nextId,
                        audioBytes: closed.audioBytes,
                        durationSeconds: Double(closed.audioBytes) / Double(AudioFormat.bytesPerSecond),
                        startedSecondsAgo: now.timeIntervalSince(closed.startedAt),
                        endedSecondsAgo: now.timeIntervalSince(closed.endedAt),
                        isOpen: false
                    )
                )
                nextId += 1
            }

            if openSessionAudioBytes > 0, let startedAt = openSessionStartedAt {
                summaries.append(
                    SessionSummary(
                        id: nextId,
                        audioBytes: openSessionAudioBytes,
                        durationSeconds: Double(openSessionAudioBytes) / Double(AudioFormat.bytesPerSecond),
                        startedSecondsAgo: now.timeIntervalSince(startedAt),
                        endedSecondsAgo: nil,
                        isOpen: true
                    )
                )
            }

            return summaries
        }
    }

    /// PCM for one session (1-based id), or nil if unknown / empty.
    public func snapshotForSession(id: Int) -> Data? {
        queue.sync {
            let pcm = snapshotPCMUnlocked(minutes: nil)
            let ranges = SessionCatalog.audioRanges(in: pcm)
            guard id >= 1, id <= ranges.count else { return nil }
            let range = ranges[id - 1]
            guard !range.isEmpty else { return nil }
            return pcm.subdata(in: range)
        }
    }

    /// Returns contiguous PCM for the last `minutes` of audio (or all filled when nil).
    public func snapshotForDump(minutes: Int?) -> Data {
        queue.sync {
            snapshotPCMUnlocked(minutes: minutes)
        }
    }

    private func snapshotPCMUnlocked(minutes: Int?) -> Data {
        let byteCount = DumpRange.byteCount(minutes: minutes, filledBytes: ring.filledBytes)
        let segments = ring.slice(lastBytes: byteCount)
        return segments.reduce(into: Data()) { $0.append($1) }
    }

    private func closeOpenSession(endedAt: Date) {
        guard openSessionAudioBytes > 0, let startedAt = openSessionStartedAt else {
            openSessionAudioBytes = 0
            openSessionStartedAt = nil
            return
        }
        closedSessions.append(
            ClosedSession(
                audioBytes: openSessionAudioBytes,
                startedAt: startedAt,
                endedAt: endedAt
            )
        )
        openSessionAudioBytes = 0
        openSessionStartedAt = nil
    }
}