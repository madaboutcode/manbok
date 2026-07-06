import Foundation

// MARK: - CONTRACT: SessionRegistry
//
// GUARANTEES:
// - One open session per bundle ID; multiple concurrent open sessions across different apps.
// - Stable ids: monotonic UInt64, assigned at open, never reused. Calling openSession(bundleID:)
//   again while that bundle already has an open session returns the SAME stable id (no
//   duplicate session, no id churn).
// - append(data:) writes once to the shared ring, then feeds every open session's
//   IncrementalSampler with the same chunk — sessions are overlapping VIEWS over one ring
//   (tracked as an offset range), not disjoint byte owners.
// - openSession(bundleID:, displayName:) creates a per-app open session anchored at the ring's
//   current totalBytesWritten.
// - closeSession(bundleID:) finalizes peaks via WaveformSampler and moves the session to the
//   closed list (a no-op if that bundle has no open session).
// - listSessions() returns [SessionSnapshot] newest-start-first; lazily prunes closed sessions
//   whose start has been overwritten by ring wrap or resize (expire-whole per glossary: a
//   closed session vanishes as a whole the moment its beginning is overwritten — no clamping
//   to surviving bytes). Open sessions shrink from the front dynamically.
// - snapshotForSession(stableId:) returns PCM Data for fully-intact closed sessions or the
//   current range of open sessions; nil if the id is unknown or the session has expired.
// - resize(to:) does a preserve-newest-that-fits copy (via ByteRingBuffer's seeded init — SK2)
//   and expires closed sessions that fully fell off; open sessions keep shrinking from the
//   front dynamically (same mechanism as ring-wrap, no special-casing needed here).
// - All mutation serialized on a private DispatchQueue (same pattern as the RecordingSession
//   it replaces).
//
// EXPECTS:
// - bundleID non-empty; append(data:) called only while capture is active.
//
// FAILURE BEHAVIOR:
// - snapshotForSession for an unknown or fully-expired stable id → nil.
// - resize signature is `throws` per design (alloc failure -> state unchanged); the current
//   ByteRingBuffer seeded init has no recoverable failure path (Swift array allocation failure
//   is a precondition crash, not a thrown error), so nothing throws today. Kept `throws` to
//   match the contracted call site and design's own FAILURE clause.
//
// DOES NOT:
// - Start/stop capture, write files, or import AppKit/AVFoundation.
//
// IMPLEMENTATION NOTE (caller-migration additions beyond the design's method list):
// - `snapshotForDump(minutes:)` — raw last-N-minutes ring slice, independent of session
//   identity. Needed because ListenerService.dump(minutes:) (CLI "dump last N minutes", no
//   session arg) has no per-app framing; this is a direct port of the old
//   RecordingSession.snapshotForDump(minutes:).
// - `setDisplayName(bundleID:displayName:)` — updates an already-open session's label without
//   touching its byte range. Needed by ListenerService's transitional legacy-session shim
//   (OpportunisticCaptureController still relabels one "union" session as the joined app set
//   changes, calling `setSessionAppName` possibly before an app name is known); CaptureOrchestrator
//   (Phase 2 task 2.1) will supply the correct displayName at `openSession` time from the start
//   and shouldn't need this.

/// Owns the shared byte ring, all per-app sessions, stable ids, and waveform peaks.
public final class SessionRegistry {
    /// One session as reported to callers — a point-in-time view, not a live reference.
    public struct SessionSnapshot: Sendable, Equatable {
        public let stableId: UInt64
        public let bundleID: String
        public let displayName: String
        public let durationSeconds: TimeInterval
        public let startedAt: Date
        public let endedAt: Date?
        public let isOpen: Bool
        public let audioBytes: Int
        public let peaks: [Float]
    }

    private struct OpenSession {
        let stableId: UInt64
        let bundleID: String
        var displayName: String
        let startTotalOffset: Int64
        let startedAt: Date
        let incrementalSampler: WaveformSampler.IncrementalSampler
    }

    private struct ClosedSession {
        let stableId: UInt64
        let bundleID: String
        let displayName: String
        let startTotalOffset: Int64
        let audioBytes: Int
        let startedAt: Date
        let endedAt: Date
        let peaks: [Float]
    }

    private static let waveformBuckets = 100

    private var ring: ByteRingBuffer
    private var openSessions: [String: OpenSession] = [:]
    private var closedSessions: [ClosedSession] = []
    private var nextStableId: UInt64 = 1
    private let queue = DispatchQueue(label: "ai.manbok.app.session-registry")

    public init(ringCapacity: Int = AudioFormat.capacityBytes) {
        self.ring = ByteRingBuffer(capacityBytes: ringCapacity)
    }

    /// Rebuilds a registry from a checkpoint: seeds the ring with `ringData`, restores every
    /// persisted session as closed, and recomputes peaks from PCM (peaks are never persisted).
    public init(restoredFrom manifest: CheckpointManifest, ringData: Data) {
        self.ring = ByteRingBuffer(
            capacityBytes: manifest.ringCapacityBytes,
            seededTotalBytesWritten: manifest.ringTotalBytesWritten,
            initialData: ringData
        )
        self.closedSessions = manifest.sessions.map { session in
            let pcm = ring.read(fromTotalOffset: session.startTotalOffset, count: session.audioBytes)
            return ClosedSession(
                stableId: session.stableId,
                bundleID: session.bundleID,
                displayName: session.displayName,
                startTotalOffset: session.startTotalOffset,
                audioBytes: session.audioBytes,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                peaks: WaveformSampler.peaks(from: pcm, buckets: Self.waveformBuckets)
            )
        }
        self.nextStableId = manifest.nextStableId
    }

    public var filledBytes: Int {
        queue.sync { ring.filledBytes }
    }

    public var capacityBytes: Int {
        queue.sync { ring.capacityBytes }
    }

    public var anySessionOpen: Bool {
        queue.sync { !openSessions.isEmpty }
    }

    /// Writes once to the shared ring, then feeds every open session's incremental sampler.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.sync {
            ring.write(data)
            for key in openSessions.keys {
                openSessions[key]?.incrementalSampler.append(chunk: data)
            }
        }
    }

    /// Creates (or returns the existing) open session for `bundleID`, anchored at the ring's
    /// current write position.
    @discardableResult
    public func openSession(bundleID: String, displayName: String) -> UInt64 {
        queue.sync {
            if let existing = openSessions[bundleID] { return existing.stableId }
            let stableId = nextStableId
            nextStableId += 1
            openSessions[bundleID] = OpenSession(
                stableId: stableId,
                bundleID: bundleID,
                displayName: displayName,
                startTotalOffset: ring.totalBytesWritten,
                startedAt: Date(),
                incrementalSampler: WaveformSampler.IncrementalSampler(provisionalBucketCount: Self.waveformBuckets)
            )
            return stableId
        }
    }

    /// Relabels an already-open session without touching its byte range. No-op if `bundleID`
    /// has no open session. See the IMPLEMENTATION NOTE above — a transitional shim need.
    public func setDisplayName(bundleID: String, displayName: String) {
        queue.sync {
            openSessions[bundleID]?.displayName = displayName
        }
    }

    /// Finalizes `bundleID`'s open session (waveform peaks + closed-list entry). No-op if
    /// `bundleID` has no open session, or if the surviving byte range is already empty
    /// (ring wrapped the entire session away before it could close).
    public func closeSession(bundleID: String, endedAt: Date = Date()) {
        queue.sync {
            guard let open = openSessions.removeValue(forKey: bundleID) else { return }
            let effectiveStart = max(open.startTotalOffset, ring.oldestValidOffset)
            let effectiveBytes = Int(ring.totalBytesWritten - effectiveStart)
            guard effectiveBytes > 0 else { return }
            closedSessions.append(
                ClosedSession(
                    stableId: open.stableId,
                    bundleID: open.bundleID,
                    displayName: open.displayName,
                    startTotalOffset: effectiveStart,
                    audioBytes: effectiveBytes,
                    startedAt: open.startedAt,
                    endedAt: endedAt,
                    peaks: open.incrementalSampler.finalize(buckets: Self.waveformBuckets)
                )
            )
        }
    }

    /// All sessions, newest-start-first. Expired (fully overwritten) closed sessions are
    /// dropped; partially-overwritten ones are clamped to their surviving byte range, not
    /// dropped (see CONTRACT).
    public func listSessions() -> [SessionSnapshot] {
        queue.sync {
            expireStaleUnlocked()
            var snapshots: [SessionSnapshot] = []

            for closed in closedSessions {
                guard let range = survivingRange(of: closed) else { continue }
                snapshots.append(
                    SessionSnapshot(
                        stableId: closed.stableId,
                        bundleID: closed.bundleID,
                        displayName: closed.displayName,
                        durationSeconds: Double(range.count) / Double(AudioFormat.bytesPerSecond),
                        startedAt: closed.startedAt,
                        endedAt: closed.endedAt,
                        isOpen: false,
                        audioBytes: range.count,
                        peaks: closed.peaks
                    )
                )
            }

            for open in openSessions.values {
                let effectiveStart = max(open.startTotalOffset, ring.oldestValidOffset)
                let effectiveBytes = Int(ring.totalBytesWritten - effectiveStart)
                guard effectiveBytes > 0 else { continue }
                snapshots.append(
                    SessionSnapshot(
                        stableId: open.stableId,
                        bundleID: open.bundleID,
                        displayName: open.displayName,
                        durationSeconds: Double(effectiveBytes) / Double(AudioFormat.bytesPerSecond),
                        startedAt: open.startedAt,
                        endedAt: nil,
                        isOpen: true,
                        audioBytes: effectiveBytes,
                        peaks: open.incrementalSampler.currentPeaks(buckets: Self.waveformBuckets)
                    )
                )
            }

            snapshots.sort { $0.startedAt > $1.startedAt }
            return snapshots
        }
    }

    /// PCM for one session by stable id, clamped to its surviving byte range. Nil if unknown
    /// or fully expired.
    public func snapshotForSession(stableId: UInt64) -> Data? {
        queue.sync {
            expireStaleUnlocked()

            if let closed = closedSessions.first(where: { $0.stableId == stableId }) {
                guard let range = survivingRange(of: closed) else { return nil }
                return ring.read(fromTotalOffset: range.start, count: range.count)
            }

            if let open = openSessions.values.first(where: { $0.stableId == stableId }) {
                let effectiveStart = max(open.startTotalOffset, ring.oldestValidOffset)
                let effectiveBytes = Int(ring.totalBytesWritten - effectiveStart)
                guard effectiveBytes > 0 else { return nil }
                return ring.read(fromTotalOffset: effectiveStart, count: effectiveBytes)
            }

            return nil
        }
    }

    /// Raw last-`minutes` (or all filled, when nil) ring bytes — no session framing. Port of
    /// RecordingSession.snapshotForDump(minutes:), needed for the CLI's session-less dump path.
    public func snapshotForDump(minutes: Int?) -> Data {
        queue.sync {
            let byteCount = DumpRange.byteCount(minutes: minutes, filledBytes: ring.filledBytes)
            let segments = ring.slice(lastBytes: byteCount)
            return segments.reduce(into: Data()) { $0.append($1) }
        }
    }

    /// Snapshot of the ring + all sessions for persistence. Read-only: open sessions are frozen
    /// into the returned manifest as ended, but the live registry is left unchanged.
    public func checkpoint() -> (manifest: CheckpointManifest, ringData: Data) {
        queue.sync {
            let frozenAt = Date()
            var persisted: [PersistedSession] = closedSessions.map {
                PersistedSession(
                    stableId: $0.stableId,
                    bundleID: $0.bundleID,
                    displayName: $0.displayName,
                    startTotalOffset: $0.startTotalOffset,
                    audioBytes: $0.audioBytes,
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt
                )
            }
            persisted += openSessions.values.compactMap { open in
                let effectiveStart = max(open.startTotalOffset, ring.oldestValidOffset)
                let effectiveBytes = Int(ring.totalBytesWritten - effectiveStart)
                guard effectiveBytes > 0 else { return nil }
                return PersistedSession(
                    stableId: open.stableId,
                    bundleID: open.bundleID,
                    displayName: open.displayName,
                    startTotalOffset: effectiveStart,
                    audioBytes: effectiveBytes,
                    startedAt: open.startedAt,
                    endedAt: frozenAt
                )
            }

            let ringData = ring.slice(lastBytes: ring.filledBytes).reduce(into: Data()) { $0.append($1) }
            let manifest = CheckpointManifest(
                savedAt: frozenAt,
                ringCapacityBytes: ring.capacityBytes,
                ringFilledBytes: ring.filledBytes,
                ringTotalBytesWritten: ring.totalBytesWritten,
                nextStableId: nextStableId,
                sessions: persisted
            )
            return (manifest, ringData)
        }
    }

    /// Dry-run preview of `resize(to:)`: how many sessions would be lost if we resized now?
    public func sessionsLost(ifResizedTo preset: BufferPolicy.Preset) -> Int {
        queue.sync {
            let ranges: [BufferPolicy.SessionByteRange] = closedSessions.map {
                BufferPolicy.SessionByteRange(startTotalOffset: $0.startTotalOffset, audioBytes: $0.audioBytes)
            } + openSessions.values.map {
                let effectiveBytes = Int(ring.totalBytesWritten - max($0.startTotalOffset, ring.oldestValidOffset))
                return BufferPolicy.SessionByteRange(startTotalOffset: $0.startTotalOffset, audioBytes: effectiveBytes)
            }
            return BufferPolicy.sessionsLost(
                currentSessions: ranges,
                targetPreset: preset,
                ringTotalWritten: ring.totalBytesWritten
            )
        }
    }

    /// Preserve-newest-that-fits resize. No-op if `preset`'s capacity matches the current ring.
    ///
    /// Declared `throws` to match the design contract's FAILURE clause (alloc failure -> state
    /// unchanged), but nothing throws today: the seeded ByteRingBuffer init's only failure mode
    /// is a precondition (an unrecoverable crash, not a thrown error), and `keep <= newCapacity`
    /// always holds by construction. No `try` needed inside — this signature is future-proofing.
    public func resize(to preset: BufferPolicy.Preset) throws {
        queue.sync {
            let newCapacity = BufferPolicy.capacityBytes(for: preset)
            guard newCapacity != ring.capacityBytes else { return }

            let keep = min(ring.filledBytes, newCapacity)
            let initialData = ring.slice(lastBytes: keep).reduce(into: Data()) { $0.append($1) }
            ring = ByteRingBuffer(
                capacityBytes: newCapacity,
                seededTotalBytesWritten: ring.totalBytesWritten,
                initialData: initialData
            )
            expireStaleUnlocked()
        }
    }

    /// The byte range of `closed` if it still fully survives in the ring, or nil if its
    /// beginning has been overwritten. Expire-whole per glossary: a closed session vanishes as
    /// a whole the moment its beginning is overwritten.
    private func survivingRange(of closed: ClosedSession) -> (start: Int64, count: Int)? {
        let oldest = ring.oldestValidOffset
        guard closed.startTotalOffset >= oldest else { return nil }
        let count = closed.audioBytes
        guard count > 0 else { return nil }
        return (closed.startTotalOffset, count)
    }

    private func expireStaleUnlocked() {
        let oldest = ring.oldestValidOffset
        closedSessions.removeAll { $0.startTotalOffset < oldest }
    }
}
