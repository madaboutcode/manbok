import Foundation

// MARK: - CONTRACT: BufferPolicy
//
// GUARANTEES:
// - Preset.min10 is the default, matching the historical fixed 10-minute ring.
// - capacityBytes(for:) derives every byte count from AudioFormat.bytesPerMinute — no
//   duplicated magic numbers.
// - memoryCost(for:) is a human string ("~19 MB") using decimal megabytes (1_000_000 bytes),
//   rounded to the nearest whole MB.
// - sessionsLost(currentSessions:targetPreset:ringTotalWritten:) counts only sessions whose
//   entire byte range (startTotalOffset ..< startTotalOffset + audioBytes) would fall before
//   the new ring's oldest-valid-offset if resized to targetPreset right now. A session with
//   even one surviving byte is not counted as lost.
//
// EXPECTS:
// - `currentSessions` describes byte ranges already present in the ring (startTotalOffset is
//   in the same absolute-offset namespace as ByteRingBuffer.totalBytesWritten).
// - `ringTotalWritten` is the ring's current totalBytesWritten (bytes written so far, growing
//   forever, may exceed current capacity).
//
// FAILURE BEHAVIOR:
// - None (pure math; no invalid preset/input combination is possible with the closed enum).
//
// DOES NOT:
// - Persist the selected preset (see SettingsStore).
// - Perform the actual ring resize/copy (see SessionRegistry.resize).

/// Ring capacity presets and the pure math needed to reason about resizing.
public enum BufferPolicy {
    public enum Preset: String, CaseIterable, Sendable {
        case min5, min10, min30, min60, min120

        public static let `default`: Preset = .min10

        public var minutes: Int {
            switch self {
            case .min5: return 5
            case .min10: return 10
            case .min30: return 30
            case .min60: return 60
            case .min120: return 120
            }
        }
    }

    /// A session's byte range in the ring's absolute-offset namespace. Deliberately narrower
    /// than the application-layer session type (SessionRegistry's SessionSnapshot, added in a
    /// later task): resize-loss accounting only ever needs a byte range, not display identity
    /// or waveform data, so this type carries nothing else and does not duplicate that model.
    public struct SessionByteRange: Sendable, Equatable {
        public let startTotalOffset: Int64
        public let audioBytes: Int

        public init(startTotalOffset: Int64, audioBytes: Int) {
            self.startTotalOffset = startTotalOffset
            self.audioBytes = audioBytes
        }

        var endTotalOffset: Int64 { startTotalOffset + Int64(audioBytes) }
    }

    public static func capacityBytes(for preset: Preset) -> Int {
        AudioFormat.bytesPerMinute * preset.minutes
    }

    public static func memoryCost(for preset: Preset) -> String {
        let megabytes = Double(capacityBytes(for: preset)) / 1_000_000.0
        return "~\(Int(megabytes.rounded())) MB"
    }

    /// Number of `currentSessions` that would have zero surviving bytes if the ring were
    /// resized to `targetPreset` right now.
    public static func sessionsLost(
        currentSessions: [SessionByteRange],
        targetPreset: Preset,
        ringTotalWritten: Int64
    ) -> Int {
        let newCapacity = Int64(capacityBytes(for: targetPreset))
        let newOldestValidOffset = max(0, ringTotalWritten - newCapacity)
        return currentSessions.filter { $0.endTotalOffset <= newOldestValidOffset }.count
    }
}
