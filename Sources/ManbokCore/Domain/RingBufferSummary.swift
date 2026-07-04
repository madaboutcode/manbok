import Foundation

// MARK: - CONTRACT (RingBufferSummary)
//
// GUARANTEES
// - Describes filled ring bytes and derived duration at canonical PCM rate.
//
// DOES NOT
// - Read the ring buffer directly.

/// Human- and IPC-friendly view of how much audio is in the ring.
public struct RingBufferSummary: Sendable, Equatable {
    public let filledBytes: Int

    public init(filledBytes: Int) {
        self.filledBytes = max(0, filledBytes)
    }

    public var bufferedSeconds: Double {
        guard filledBytes > 0 else { return 0 }
        return Double(filledBytes) / Double(AudioFormat.bytesPerSecond)
    }

    /// Wire suffix: `ring_bytes=192000`
    public var ipcSuffix: String {
        "ring_bytes=\(filledBytes)"
    }

    /// CLI / meter: `ring=1.2 MB (~6.0s)`
    public var displaySuffix: String {
        guard filledBytes > 0 else { return "ring=empty" }
        let mb = Double(filledBytes) / 1_048_576
        let size: String
        if mb >= 0.1 {
            size = String(format: "%.1f MB", mb)
        } else {
            size = String(format: "%.0f KB", Double(filledBytes) / 1024)
        }
        return String(format: "ring=%@ (~%.1fs)", size, bufferedSeconds)
    }
}