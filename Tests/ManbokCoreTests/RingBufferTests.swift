import XCTest
@testable import ManbokCore

final class RingBufferTests: XCTestCase {
    func testCapacityIsTenMinutes() {
        XCTAssertEqual(AudioFormat.capacityBytes, 19_200_000)
        XCTAssertEqual(AudioFormat.sampleRate, 16_000)
        XCTAssertEqual(AudioFormat.channels, 1)
        XCTAssertEqual(AudioFormat.bytesPerSample, 2)

        let ring = ByteRingBuffer()
        XCTAssertEqual(ring.capacityBytes, 19_200_000)
        XCTAssertEqual(ring.filledBytes, 0)
    }

    func testWriteBeyondCapacityKeepsLastTenMinutes() {
        let capacity = AudioFormat.capacityBytes
        let oneMinute = AudioFormat.bytesPerMinute
        var ring = ByteRingBuffer(capacityBytes: capacity)

        var marker = UInt8(0)
        for _ in 0 ..< 11 {
            var minute = Data(count: oneMinute)
            minute.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for index in 0 ..< oneMinute {
                    base[index] = marker &+ UInt8(index % 256)
                }
            }
            ring.write(minute)
            marker &+= 1
        }

        XCTAssertEqual(ring.filledBytes, capacity)

        let lastTen = Data(ring.slice(lastBytes: capacity).reduce(into: Data()) { $0.append($1) })
        var expected = Data()
        for minuteIndex in 1 ..< 11 {
            var minute = Data(count: oneMinute)
            minute.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for index in 0 ..< oneMinute {
                    base[index] = UInt8(minuteIndex) &+ UInt8(index % 256)
                }
            }
            expected.append(minute)
        }

        XCTAssertEqual(lastTen, expected)
    }

    func testTotalBytesWrittenIsMonotonic() {
        var ring = ByteRingBuffer(capacityBytes: 100)
        XCTAssertEqual(ring.totalBytesWritten, 0)

        ring.write(Data(repeating: 0xAA, count: 50))
        XCTAssertEqual(ring.totalBytesWritten, 50)

        ring.write(Data(repeating: 0xBB, count: 80))
        XCTAssertEqual(ring.totalBytesWritten, 130)
        XCTAssertEqual(ring.filledBytes, 100)
        XCTAssertEqual(ring.oldestValidOffset, 30)
    }

    func testReadFromTotalOffset() {
        var ring = ByteRingBuffer(capacityBytes: 100)
        ring.write(Data(repeating: 0xAA, count: 60))
        ring.write(Data(repeating: 0xBB, count: 60))
        // Ring wrapped: totalBytesWritten=120, filled=100, oldest=20
        // Physical: [BB×60][BB×20 overwrote AA][AA×40 left from first write... no]
        // Actually: first write puts 60 AA bytes at positions 0-59
        // second write puts 60 BB bytes at positions 60-99 then wraps to 0-19
        // So ring contains: [BB×20 at 0-19][AA×40 at 20-59][BB×40 at 60-99]

        // Read the AA bytes that survived (offset 20-59, which is totalOffset 20-59)
        let surviving = ring.read(fromTotalOffset: 20, count: 40)
        XCTAssertEqual(surviving.count, 40)
        XCTAssertEqual(surviving, Data(repeating: 0xAA, count: 40))

        // Read across the wrap boundary
        let crossWrap = ring.read(fromTotalOffset: 80, count: 40)
        XCTAssertEqual(crossWrap.count, 40)
        XCTAssertEqual(crossWrap, Data(repeating: 0xBB, count: 40))

        // Read before oldest valid offset returns empty
        let expired = ring.read(fromTotalOffset: 10, count: 10)
        XCTAssertEqual(expired.count, 0)
    }

    func testMinutesClampedToFilled() {
        let oneMinute = AudioFormat.bytesPerMinute
        let filled = oneMinute * 3

        XCTAssertEqual(DumpRange.byteCount(minutes: nil, filledBytes: filled), filled)
        XCTAssertEqual(DumpRange.byteCount(minutes: 5, filledBytes: filled), filled)
        XCTAssertEqual(DumpRange.byteCount(minutes: 10, filledBytes: filled), filled)
        XCTAssertEqual(DumpRange.byteCount(minutes: 15, filledBytes: filled), filled)

        let twoMinutes = oneMinute * 2
        XCTAssertEqual(DumpRange.byteCount(minutes: 2, filledBytes: filled), twoMinutes)
        XCTAssertEqual(DumpRange.byteCount(minutes: 1, filledBytes: filled), oneMinute)

        XCTAssertEqual(DumpRange.byteCount(minutes: 3, filledBytes: 0), 0)
        XCTAssertEqual(DumpRange.byteCount(minutes: nil, filledBytes: 0), 0)
    }

    // MARK: - Seeded init (SK2 spike — SessionRegistry.resize's building block)
    //
    // Adapted from tmp/spike-resize/Tests/*/ResizeSpikeTests.swift, which proved that seeding
    // totalBytesWritten alone (delegating byte placement to the public write()) misaligns
    // physical storage against the absolute offset space. init(capacityBytes:seededTotalBytesWritten:
    // initialData:) aligns writeIndex to the seeded start offset before placing any bytes. (The
    // spike's third test exercised a spike-only `naiveSeededCopy` helper that intentionally
    // isn't ported into production code — the two tests below cover the shipped init.)

    /// byte = offset % 251, recognizable and collision-resistant enough for this test.
    private func patternedByte(_ absoluteOffset: Int64) -> UInt8 {
        UInt8(truncatingIfNeeded: absoluteOffset % 251)
    }

    private func patternedData(startingAtAbsoluteOffset start: Int64, count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0 ..< count {
            data.append(patternedByte(start + Int64(index)))
        }
        return data
    }

    /// Writes in small chunks (like real audio capture callbacks), never a single write >=
    /// capacity in one call — that hits write()'s own pre-existing phase hazard (documented on
    /// ByteRingBuffer's CONTRACT), unrelated to resize.
    private func buildWrappedRing(capacity: Int, totalWritten: Int, chunk: Int = 4_096) -> ByteRingBuffer {
        var ring = ByteRingBuffer(capacityBytes: capacity)
        var written = 0
        while written < totalWritten {
            let n = min(chunk, totalWritten - written)
            ring.write(patternedData(startingAtAbsoluteOffset: Int64(written), count: n))
            written += n
        }
        return ring
    }

    func testSeededInitPreservesOffsetsAfterWrappedShrink() {
        let old = buildWrappedRing(capacity: 30_000, totalWritten: 45_000)
        XCTAssertEqual(old.filledBytes, 30_000)
        XCTAssertEqual(old.oldestValidOffset, 15_000)

        let newCapacity = 10_000
        let keep = min(old.filledBytes, newCapacity)
        let initialData = old.slice(lastBytes: keep).reduce(Data(), +)

        var resized = ByteRingBuffer(
            capacityBytes: newCapacity,
            seededTotalBytesWritten: old.totalBytesWritten,
            initialData: initialData
        )

        XCTAssertEqual(resized.totalBytesWritten, old.totalBytesWritten)
        let oldestSurviving = old.totalBytesWritten - Int64(keep)
        XCTAssertEqual(resized.oldestValidOffset, oldestSurviving)

        for probe: Int64 in [oldestSurviving, oldestSurviving + 4_999, old.totalBytesWritten - 1] {
            let count = 50
            let available = min(count, Int(old.totalBytesWritten - probe))
            XCTAssertEqual(
                resized.read(fromTotalOffset: probe, count: count),
                patternedData(startingAtAbsoluteOffset: probe, count: available)
            )
        }

        // Offsets older than the new window read empty.
        XCTAssertEqual(resized.read(fromTotalOffset: oldestSurviving - 1, count: 10), Data())
        XCTAssertEqual(resized.read(fromTotalOffset: 0, count: 100), Data())

        // Continued writes after resize keep the offset space consistent across the boundary.
        let moreCount = 5_000
        resized.write(patternedData(startingAtAbsoluteOffset: resized.totalBytesWritten, count: moreCount))
        XCTAssertEqual(resized.totalBytesWritten, old.totalBytesWritten + Int64(moreCount))
        let straddleStart = old.totalBytesWritten - 500
        XCTAssertEqual(
            resized.read(fromTotalOffset: straddleStart, count: 1_000),
            patternedData(startingAtAbsoluteOffset: straddleStart, count: 1_000)
        )
    }

    func testSeededInitWhenInitialDataFillsCapacityExactly() {
        // The keep == newCapacity edge case: if seeding delegated to write(), its
        // "data.count >= capacity" fast path would fire and reset writeIndex to 0.
        let old = buildWrappedRing(capacity: 30_000, totalWritten: 45_000)
        let newCapacity = 30_000
        let keep = min(old.filledBytes, newCapacity)
        XCTAssertEqual(keep, newCapacity, "test precondition: initialData must exactly fill the new ring")
        let initialData = old.slice(lastBytes: keep).reduce(Data(), +)

        let resized = ByteRingBuffer(
            capacityBytes: newCapacity,
            seededTotalBytesWritten: old.totalBytesWritten,
            initialData: initialData
        )

        XCTAssertEqual(resized.totalBytesWritten, 45_000)
        XCTAssertEqual(resized.oldestValidOffset, 15_000)

        for probe: Int64 in [15_000, 20_000, 30_000, 44_999] {
            let available = min(10, Int(resized.totalBytesWritten - probe))
            XCTAssertEqual(
                resized.read(fromTotalOffset: probe, count: 10),
                patternedData(startingAtAbsoluteOffset: probe, count: available)
            )
        }
    }
}