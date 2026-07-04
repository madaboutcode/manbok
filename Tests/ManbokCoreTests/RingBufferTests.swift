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
}