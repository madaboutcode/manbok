import Foundation

// MARK: - CONTRACT: WaveformSampler
//
// GUARANTEES:
// - peaks(from:buckets:) always returns exactly `buckets` values (or [] if buckets <= 0),
//   each in 0.0...1.0, the max sample amplitude in that bucket's slice of the PCM.
// - PCM is interpreted as 16-bit little-endian mono; a trailing odd byte is dropped.
// - Empty PCM (or buckets > available samples) yields 0.0 for buckets with no samples.
// - IncrementalSampler.append(chunk:) accepts PCM chunks in arrival order; a byte split
//   across two chunks (odd-length chunk) is carried over correctly.
// - IncrementalSampler keeps a bounded (~2x provisional bucket count) internal accumulator
//   regardless of how much audio has been appended, so currentPeaks/finalize stay O(buckets).
// - IncrementalSampler.currentPeaks(buckets:) and finalize(buckets:) both return exactly
//   `buckets` values; finalize is currentPeaks called one last time (no distinct "closing"
//   step — there is no different definitive computation, just the last observation).
//
// EXPECTS:
// - buckets > 0 for a non-empty result; peaks(from:buckets: 0) returns [].
//
// FAILURE BEHAVIOR:
// - Malformed PCM (odd trailing byte) — the trailing byte is silently dropped, not an error.
//
// DOES NOT:
// - Render UI or store peaks (SessionRegistry owns storage of finalized peaks).

/// Pure PCM -> amplitude-peak computation for waveform rendering.
public enum WaveformSampler {
    /// Exactly `buckets` max-amplitude values (0.0...1.0) from 16-bit little-endian mono PCM.
    public static func peaks(from pcm: Data, buckets: Int) -> [Float] {
        guard buckets > 0 else { return [] }
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return [Float](repeating: 0, count: buckets) }

        var amplitudes = [Float](repeating: 0, count: sampleCount)
        pcm.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            for index in 0 ..< sampleCount {
                amplitudes[index] = amplitude(lo: base[index * 2], hi: base[index * 2 + 1])
            }
        }
        return bucketMax(amplitudes, into: buckets)
    }

    private static func amplitude(lo: UInt8, hi: UInt8) -> Float {
        let bits = UInt16(lo) | (UInt16(hi) << 8)
        let sample = Int16(bitPattern: bits)
        return min(1.0, abs(Float(sample)) / Float(Int16.max))
    }

    /// Bins `source` down (or sparsely up) into exactly `bucketCount` values, max per bucket.
    static func bucketMax(_ source: [Float], into bucketCount: Int) -> [Float] {
        guard bucketCount > 0 else { return [] }
        guard !source.isEmpty else { return [Float](repeating: 0, count: bucketCount) }
        var result = [Float](repeating: 0, count: bucketCount)
        for (index, value) in source.enumerated() {
            let bucketIndex = min(bucketCount - 1, (index * bucketCount) / source.count)
            result[bucketIndex] = max(result[bucketIndex], value)
        }
        return result
    }

    /// Accumulates PCM chunks for an in-progress session, keeping a bounded set of provisional
    /// max-amplitude buckets that adjacent-merge (doubling `samplesPerBucket`) once the
    /// accumulator reaches twice the provisional capacity, so memory never grows with session
    /// length.
    public final class IncrementalSampler {
        private var provisionalPeaks: [Float] = []
        private var samplesPerBucket: Int64 = 1
        private var pendingMax: Float = 0
        private var pendingCount: Int64 = 0
        private var carryByte: UInt8?
        private let provisionalCapacity: Int

        public init(provisionalBucketCount: Int = 100) {
            precondition(provisionalBucketCount > 0, "provisionalBucketCount must be positive")
            self.provisionalCapacity = provisionalBucketCount
        }

        public func append(chunk: Data) {
            guard !chunk.isEmpty else { return }
            var bytes = [UInt8](chunk)
            if let carryByte {
                bytes.insert(carryByte, at: 0)
                self.carryByte = nil
            }
            if bytes.count % 2 != 0 {
                carryByte = bytes.removeLast()
            }

            var index = 0
            while index < bytes.count {
                let value = amplitude(lo: bytes[index], hi: bytes[index + 1])
                pendingMax = max(pendingMax, value)
                pendingCount += 1
                if pendingCount >= samplesPerBucket {
                    pushProvisionalBucket(pendingMax)
                    pendingMax = 0
                    pendingCount = 0
                }
                index += 2
            }
        }

        /// Current best-effort peaks, resampled from the provisional accumulator to exactly
        /// `buckets` values. Safe to call at any time, including mid-session.
        public func currentPeaks(buckets: Int) -> [Float] {
            var snapshot = provisionalPeaks
            if pendingCount > 0 {
                snapshot.append(pendingMax)
            }
            return WaveformSampler.bucketMax(snapshot, into: buckets)
        }

        /// Final peaks at session close. Same computation as currentPeaks — there is no
        /// separate "definitive" pass, only the last observation of the same accumulator.
        public func finalize(buckets: Int) -> [Float] {
            currentPeaks(buckets: buckets)
        }

        private func pushProvisionalBucket(_ value: Float) {
            if provisionalPeaks.count >= provisionalCapacity * 2 {
                compact()
            }
            provisionalPeaks.append(value)
        }

        private func compact() {
            var merged: [Float] = []
            merged.reserveCapacity(provisionalPeaks.count / 2 + 1)
            var index = 0
            while index < provisionalPeaks.count {
                if index + 1 < provisionalPeaks.count {
                    merged.append(max(provisionalPeaks[index], provisionalPeaks[index + 1]))
                } else {
                    merged.append(provisionalPeaks[index])
                }
                index += 2
            }
            provisionalPeaks = merged
            samplesPerBucket *= 2
        }
    }
}
