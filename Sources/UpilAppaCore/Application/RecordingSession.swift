import Foundation

// MARK: - CONTRACT: RecordingSession
//
// GUARANTEES:
// - Only mutates ring on capture callback path (serialized on internal queue).
// - appendSilence(seconds:) writes zero PCM for session markers (same queue as append).
// - snapshotForDump(minutes:) is consistent — no partial write visible.
//
// EXPECTS:
// - AudioCapturing delivers converted PCM only; ListenerService forwards append calls.
//
// FAILURE BEHAVIOR:
// - Capture stop → session quiescent; ring contents preserved until process exit.
//
// DOES NOT:
// - Start/stop capture, write files, or encode WAV.

/// Owns the byte ring and exposes thread-safe append and dump snapshots.
public final class RecordingSession {
    private var ring = ByteRingBuffer()
    private var lastAppendAt: Date?
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
        queue.sync {
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
            ring.write(Data(count: byteCount))
            lastAppendAt = Date()
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
}