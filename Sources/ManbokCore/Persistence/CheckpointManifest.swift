import Foundation

// MARK: - CONTRACT: CheckpointManifest
//
// GUARANTEES:
// - Pure Codable value type — no I/O, no side effects.
// - formatVersion identifies the schema; unknown versions are rejected by the restore path.
// - sessions contains only closed (or frozen-open) sessions — no live sampler state.
// - Peaks and durations are NOT stored; they are recomputed from PCM on restore.
//
// EXPECTS:
// - ringFilledBytes == the byte count of the accompanying PCM data file.
// - ringTotalBytesWritten and session offsets are in the same absolute-offset namespace
//   as ByteRingBuffer.totalBytesWritten.
//
// DOES NOT:
// - Touch the filesystem (see StatePersistenceService in ManbokPlatform).
// - Store derived data (peaks, durations) — those are recomputed from the ring PCM.

/// Metadata manifest for a persisted ring buffer + session checkpoint.
public struct CheckpointManifest: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let savedAt: Date
    public let ringCapacityBytes: Int
    public let ringFilledBytes: Int
    public let ringTotalBytesWritten: Int64
    public let nextStableId: UInt64
    public let sessions: [PersistedSession]

    public init(
        savedAt: Date = Date(),
        ringCapacityBytes: Int,
        ringFilledBytes: Int,
        ringTotalBytesWritten: Int64,
        nextStableId: UInt64,
        sessions: [PersistedSession]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.savedAt = savedAt
        self.ringCapacityBytes = ringCapacityBytes
        self.ringFilledBytes = ringFilledBytes
        self.ringTotalBytesWritten = ringTotalBytesWritten
        self.nextStableId = nextStableId
        self.sessions = sessions
    }
}

/// A session boundary record — enough to reconstruct a ClosedSession from the ring PCM.
public struct PersistedSession: Codable, Sendable, Equatable {
    public let stableId: UInt64
    public let bundleID: String
    public let displayName: String
    public let startTotalOffset: Int64
    public let audioBytes: Int
    public let startedAt: Date
    public let endedAt: Date

    public init(
        stableId: UInt64,
        bundleID: String,
        displayName: String,
        startTotalOffset: Int64,
        audioBytes: Int,
        startedAt: Date,
        endedAt: Date
    ) {
        self.stableId = stableId
        self.bundleID = bundleID
        self.displayName = displayName
        self.startTotalOffset = startTotalOffset
        self.audioBytes = audioBytes
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}
