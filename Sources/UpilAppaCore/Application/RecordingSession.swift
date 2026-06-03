import Foundation

// MARK: - CONTRACT: RecordingSession
//
// GUARANTEES:
// - Only mutates ring on capture callback path (serialized on internal queue).
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
    private let queue = DispatchQueue(label: "ai.upil.appa.recording-session")

    public init() {}

    public var filledBytes: Int {
        queue.sync { ring.filledBytes }
    }

    /// Appends PCM from the capture sink (serialized with snapshot reads).
    public func append(_ data: Data) {
        queue.sync { ring.write(data) }
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