import XCTest
@testable import UpilAppaCore

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