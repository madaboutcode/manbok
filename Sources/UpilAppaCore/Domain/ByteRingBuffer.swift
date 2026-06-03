import Foundation

// MARK: - CONTRACT: ByteRingBuffer
//
// GUARANTEES:
// - After write(_:), total stored length ≤ capacityBytes; oldest bytes overwritten.
// - slice(lastBytes:) returns 1 or 2 Data segments that concatenate to exactly
//   min(requested, filled) bytes, in chronological order.
// - Thread-safety: caller must serialize access (RecordingSession owns the queue).
//
// EXPECTS:
// - Writes are multiples of bytesPerFrame or callers truncate consistently.
//
// FAILURE BEHAVIOR:
// - write larger than capacity → only the trailing capacityBytes of the chunk are kept.
//
// DOES NOT:
// - Know WAV, files, or time in minutes (see DumpRange).

/// Fixed-capacity byte ring for canonical PCM chunks.
public struct ByteRingBuffer {
    private var storage: [UInt8]
    private var writeIndex = 0
    private var filled = 0

    public init(capacityBytes: Int = AudioFormat.capacityBytes) {
        precondition(capacityBytes > 0, "capacityBytes must be positive")
        storage = [UInt8](repeating: 0, count: capacityBytes)
    }

    public var capacityBytes: Int { storage.count }

    public var filledBytes: Int { filled }

    public mutating func write(_ data: Data) {
        guard !data.isEmpty else { return }

        let capacity = storage.count
        if data.count >= capacity {
            let tailStart = data.count - capacity
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                storage.withUnsafeMutableBufferPointer { dest in
                    dest.baseAddress!.update(from: base.advanced(by: tailStart), count: capacity)
                }
            }
            writeIndex = 0
            filled = capacity
            return
        }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for offset in 0 ..< data.count {
                storage[writeIndex] = base[offset]
                writeIndex = (writeIndex + 1) % capacity
                if filled < capacity {
                    filled += 1
                }
            }
        }
    }

    /// Returns one or two segments covering the last `lastBytes` stored bytes (chronological).
    public func slice(lastBytes: Int) -> [Data] {
        let count = min(max(lastBytes, 0), filled)
        guard count > 0 else { return [] }

        let capacity = storage.count
        if filled < capacity {
            let start = filled - count
            return [Data(storage[start ..< filled])]
        }

        let start = (writeIndex - count + capacity) % capacity
        if start + count <= capacity {
            return [Data(storage[start ..< start + count])]
        }
        let firstLength = capacity - start
        let secondLength = count - firstLength
        return [
            Data(storage[start ..< capacity]),
            Data(storage[0 ..< secondLength]),
        ]
    }
}