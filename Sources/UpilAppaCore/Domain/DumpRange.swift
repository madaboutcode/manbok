import Foundation

// MARK: - CONTRACT: DumpRange
//
// GUARANTEES:
// - nil minutes → all filled content (byte count == filledBytes).
// - minutes clamped to ≤ bufferMinutes (10) and ≤ filled duration in bytes.
// - Returns 0 only when the ring is empty (filledBytes == 0).
//
// EXPECTS:
// - filledBytes reflects the current ByteRingBuffer.filledBytes.
//
// FAILURE BEHAVIOR:
// - N/A (pure calculation; no I/O).
//
// DOES NOT:
// - Perform I/O or read the ring buffer directly.

/// Maps dump duration (minutes) and fill level to a byte slice length.
public enum DumpRange {
    public static func byteCount(minutes: Int?, filledBytes: Int) -> Int {
        guard filledBytes > 0 else { return 0 }
        guard let minutes else { return filledBytes }

        let clampedMinutes = min(max(minutes, 0), AudioFormat.bufferMinutes)
        let requested = clampedMinutes * AudioFormat.bytesPerMinute
        return min(requested, filledBytes)
    }
}