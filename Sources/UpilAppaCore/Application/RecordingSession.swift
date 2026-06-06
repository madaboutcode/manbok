import Foundation

// MARK: - CONTRACT: RecordingSession
//
// GUARANTEES:
// - Sessions tracked as (startTotalOffset, byteCount) in ring coordinates.
// - Expired sessions (bytes overwritten by ring wrap) lazily discarded on close/list/snapshot.
// - snapshotForSession(id:) reads exact bytes from ring via absolute offset — O(1) lookup.
// - snapshotForDump(minutes:) returns raw ring bytes — no gap scanning.
// - closeSession() finalizes the open session as metadata only — no bytes written to ring.
//
// EXPECTS:
// - AudioCapturing delivers converted PCM only; ListenerService forwards append calls.
// - ByteRingBuffer.totalBytesWritten is monotonic and serialized by this queue.
//
// FAILURE BEHAVIOR:
// - Capture stop → session quiescent; ring contents preserved until process exit.
//
// DOES NOT:
// - Start/stop capture, write files, encode WAV, or embed gap markers.

/// Owns the byte ring and exposes thread-safe append and dump snapshots.
public final class RecordingSession {
    private struct ClosedSession {
        let startTotalOffset: Int64
        let audioBytes: Int
        let startedAt: Date
        let endedAt: Date
        let appName: String?
    }

    private var ring: ByteRingBuffer
    private var lastAppendAt: Date?
    private var closedSessions: [ClosedSession] = []
    private var openSessionStartedAt: Date?
    private var openSessionAudioBytes = 0
    private var openSessionStartTotalOffset: Int64 = 0
    private var openSessionAppName: String?
    private let queue = DispatchQueue(label: "ai.upil.appa.recording-session")

    public init(ringCapacity: Int = AudioFormat.capacityBytes) {
        self.ring = ByteRingBuffer(capacityBytes: ringCapacity)
    }

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
                openSessionStartTotalOffset = ring.totalBytesWritten
            }
            openSessionAudioBytes += data.count
            ring.write(data)
            lastAppendAt = Date()
        }
    }

    /// Sets the app name for the currently open session (called when capture starts or apps change).
    public func setOpenSessionAppName(_ name: String?) {
        queue.sync { openSessionAppName = name }
    }

    /// Finalizes the open session as metadata only — no bytes written to ring.
    public func closeSession(appName: String? = nil) {
        queue.sync {
            if let appName { openSessionAppName = appName }
            closeOpenSession(endedAt: Date())
        }
    }

    /// Sessions in chronological order (1-based ids). Open session is last when present.
    public func listSessions(now: Date = Date()) -> [SessionSummary] {
        queue.sync {
            expireStaleUnlocked()
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
                        isOpen: false,
                        appName: closed.appName
                    )
                )
                nextId += 1
            }

            if openSessionAudioBytes > 0, let startedAt = openSessionStartedAt {
                let effectiveStart = max(openSessionStartTotalOffset, ring.oldestValidOffset)
                let effectiveBytes = Int(ring.totalBytesWritten - effectiveStart)
                if effectiveBytes > 0 {
                    summaries.append(
                        SessionSummary(
                            id: nextId,
                            audioBytes: effectiveBytes,
                            durationSeconds: Double(effectiveBytes) / Double(AudioFormat.bytesPerSecond),
                            startedSecondsAgo: now.timeIntervalSince(startedAt),
                            endedSecondsAgo: nil,
                            isOpen: true,
                            appName: openSessionAppName
                        )
                    )
                }
            }

            return summaries
        }
    }

    /// PCM for one session (1-based id), or nil if unknown / empty.
    public func snapshotForSession(id: Int) -> Data? {
        queue.sync {
            expireStaleUnlocked()
            let allSessions = closedSessions + openSessionEntry()
            guard id >= 1, id <= allSessions.count else { return nil }
            let session = allSessions[id - 1]
            guard session.audioBytes > 0 else { return nil }
            return ring.read(fromTotalOffset: session.startTotalOffset, count: session.audioBytes)
        }
    }

    /// Returns contiguous PCM for the last `minutes` of audio (or all filled when nil).
    public func snapshotForDump(minutes: Int?) -> Data {
        queue.sync {
            let byteCount = DumpRange.byteCount(minutes: minutes, filledBytes: ring.filledBytes)
            let segments = ring.slice(lastBytes: byteCount)
            return segments.reduce(into: Data()) { $0.append($1) }
        }
    }

    private func closeOpenSession(endedAt: Date) {
        guard openSessionAudioBytes > 0, let startedAt = openSessionStartedAt else {
            openSessionAudioBytes = 0
            openSessionStartedAt = nil
            openSessionStartTotalOffset = 0
            openSessionAppName = nil
            return
        }
        closedSessions.append(
            ClosedSession(
                startTotalOffset: openSessionStartTotalOffset,
                audioBytes: openSessionAudioBytes,
                startedAt: startedAt,
                endedAt: endedAt,
                appName: openSessionAppName
            )
        )
        openSessionAudioBytes = 0
        openSessionStartedAt = nil
        openSessionStartTotalOffset = 0
        openSessionAppName = nil
    }

    private func expireStaleUnlocked() {
        let oldest = ring.oldestValidOffset
        while let first = closedSessions.first, first.startTotalOffset < oldest {
            closedSessions.removeFirst()
        }
    }

    private func openSessionEntry() -> [ClosedSession] {
        guard openSessionAudioBytes > 0, let startedAt = openSessionStartedAt else { return [] }
        let effectiveStart = max(openSessionStartTotalOffset, ring.oldestValidOffset)
        let effectiveBytes = Int(ring.totalBytesWritten - effectiveStart)
        guard effectiveBytes > 0 else { return [] }
        return [ClosedSession(
            startTotalOffset: effectiveStart,
            audioBytes: effectiveBytes,
            startedAt: startedAt,
            endedAt: Date(),
            appName: openSessionAppName
        )]
    }
}
