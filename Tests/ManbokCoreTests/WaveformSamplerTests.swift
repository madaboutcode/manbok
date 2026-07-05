import XCTest
@testable import ManbokCore

final class WaveformSamplerTests: XCTestCase {
    // MARK: - Helpers

    /// Builds 16-bit little-endian mono PCM from a sequence of Int16 samples.
    private func pcm(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }

    // MARK: - peaks(from:buckets:)

    func testSilenceProducesAllZeroPeaks() {
        let data = pcm([Int16](repeating: 0, count: 100))
        let peaks = WaveformSampler.peaks(from: data, buckets: 10)
        XCTAssertEqual(peaks.count, 10)
        XCTAssertTrue(peaks.allSatisfy { $0 == 0.0 })
    }

    func testEmptyDataProducesExactBucketCountOfZeros() {
        let peaks = WaveformSampler.peaks(from: Data(), buckets: 8)
        XCTAssertEqual(peaks, [Float](repeating: 0, count: 8))
    }

    func testZeroBucketsRequestedReturnsEmptyArray() {
        XCTAssertEqual(WaveformSampler.peaks(from: pcm([1, 2, 3]), buckets: 0), [])
    }

    func testKnownFullScaleRegionProducesExpectedPeaks() {
        // 8 samples, 4 buckets (2 samples/bucket). Only samples 2-3 (bucket 1) are full-scale.
        var samples = [Int16](repeating: 0, count: 8)
        samples[2] = Int16.max
        samples[3] = Int16.min // abs(min) clamps to 1.0, not > 1.0
        let peaks = WaveformSampler.peaks(from: pcm(samples), buckets: 4)
        XCTAssertEqual(peaks.count, 4)
        XCTAssertEqual(peaks, [0.0, 1.0, 0.0, 0.0])
    }

    func testDataSmallerThanBucketCountStillReturnsExactBucketCount() {
        // 3 samples, 10 buckets — most buckets have no samples and stay at 0.
        let samples: [Int16] = [0, Int16.max, 0]
        let peaks = WaveformSampler.peaks(from: pcm(samples), buckets: 10)
        XCTAssertEqual(peaks.count, 10)
        XCTAssertEqual(peaks.filter { $0 > 0 }.count, 1, "exactly one sample was non-zero")
        XCTAssertEqual(peaks.max(), 1.0)
    }

    func testOddByteCountDropsTrailingByteInsteadOfCrashing() {
        // 2 full samples (4 bytes) + 1 trailing incomplete byte — must not crash, and the
        // trailing byte must not be interpreted as a sample.
        var data = pcm([0, Int16.max])
        data.append(0xFF)
        let peaks = WaveformSampler.peaks(from: data, buckets: 2)
        XCTAssertEqual(peaks, [0.0, 1.0])
    }

    // MARK: - IncrementalSampler

    func testIncrementalSamplerOnSilenceIsAllZero() {
        let sampler = WaveformSampler.IncrementalSampler()
        sampler.append(chunk: pcm([Int16](repeating: 0, count: 50)))
        XCTAssertEqual(sampler.currentPeaks(buckets: 5), [Float](repeating: 0, count: 5))
    }

    func testIncrementalSamplerHandlesByteSplitAcrossChunks() {
        // Same PCM, but the chunk boundary lands mid-sample (odd byte count on the first
        // chunk). The carried byte must be stitched back together correctly.
        let samples: [Int16] = [0, Int16.max, 0, Int16.max]
        let data = pcm(samples)

        let whole = WaveformSampler.IncrementalSampler()
        whole.append(chunk: data)

        let split = WaveformSampler.IncrementalSampler()
        split.append(chunk: data.subdata(in: 0 ..< 3)) // 1.5 samples
        split.append(chunk: data.subdata(in: 3 ..< data.count))

        XCTAssertEqual(whole.currentPeaks(buckets: 4), split.currentPeaks(buckets: 4))
    }

    func testIncrementalMatchesBatchBelowCompactionThreshold() {
        // Below the default provisional capacity (100 buckets, compaction triggers at 200
        // samples), the incremental accumulator holds one provisional bucket per raw sample —
        // identical to the batch path's per-sample array. No discretization loss is possible,
        // so this asserts exact equality (tolerance 0).
        let sampleCount = 150
        var samples = [Int16](repeating: 0, count: sampleCount)
        for index in stride(from: 10, to: sampleCount, by: 17) {
            samples[index] = Int16.max / 2
        }
        let data = pcm(samples)

        let batch = WaveformSampler.peaks(from: data, buckets: 20)

        let sampler = WaveformSampler.IncrementalSampler()
        sampler.append(chunk: data)
        let incremental = sampler.currentPeaks(buckets: 20)

        XCTAssertEqual(batch, incremental)
    }

    func testIncrementalApproximatesBatchAfterCompaction() {
        // 1000 samples forces multiple provisional-bucket compactions (capacity default is
        // 100, doubling at 200/400/800 samples), so the incremental accumulator ends up
        // coarser than the batch path's exact per-sample bucketing. A monotonic ramp keeps
        // that discretization gap small and bounded (no sharp step for a boundary to blur
        // across), unlike a single narrow spike would. Tolerance of 0.08 covers the combined
        // final-bucket width (1000/20 samples ~= slope*50 = 0.05) plus the provisional
        // compaction's own bucket width by the end (~8 samples ~= slope*8 = 0.008) with margin.
        let sampleCount = 1000
        let samples: [Int16] = (0 ..< sampleCount).map { index in
            Int16(Double(index) / Double(sampleCount) * Double(Int16.max))
        }
        let data = pcm(samples)

        let batch = WaveformSampler.peaks(from: data, buckets: 20)

        let sampler = WaveformSampler.IncrementalSampler()
        // Feed in irregular chunk sizes (including odd lengths) to exercise carry-byte logic
        // while accumulating.
        var offset = 0
        let chunkSizes = [777, 501, 300, 1, 421]
        for size in chunkSizes {
            let end = min(offset + size, data.count)
            guard end > offset else { break }
            sampler.append(chunk: data.subdata(in: offset ..< end))
            offset = end
        }
        if offset < data.count {
            sampler.append(chunk: data.subdata(in: offset ..< data.count))
        }
        let incremental = sampler.currentPeaks(buckets: 20)

        XCTAssertEqual(batch.count, incremental.count)
        for (index, (batchValue, incrementalValue)) in zip(batch, incremental).enumerated() {
            XCTAssertEqual(
                batchValue, incrementalValue, accuracy: 0.08,
                "bucket \(index) diverged beyond tolerance"
            )
        }
    }

    func testFinalizeReturnsSameValueAsCurrentPeaks() {
        let sampler = WaveformSampler.IncrementalSampler()
        sampler.append(chunk: pcm([0, Int16.max, 0, Int16.max / 2]))
        XCTAssertEqual(sampler.finalize(buckets: 4), sampler.currentPeaks(buckets: 4))
    }
}
