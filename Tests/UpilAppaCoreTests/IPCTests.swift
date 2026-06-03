import XCTest
@testable import UpilAppaCore

final class IPCTests: XCTestCase {
    func testParseDumpWithMinutes() {
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 3"), .dump(minutes: 3))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 3\n"), .dump(minutes: 3))
        XCTAssertEqual(IPCCommand.parse(line: "dump 5"), .dump(minutes: 5))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP"), .dump(minutes: nil))
        XCTAssertNil(IPCCommand.parse(line: "DUMP x"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP 3 extra"))
    }

    func testCommandWireLineRoundTrip() {
        XCTAssertEqual(IPCCommand.dump(minutes: 3).wireLine, "DUMP 3")
        XCTAssertEqual(IPCCommand.parse(line: IPCCommand.dump(minutes: 3).wireLine), .dump(minutes: 3))
    }

    func testResponseSerializeAndParse() {
        let path = URL(fileURLWithPath: "/tmp/upil-appa-test.wav")
        let ring = RingBufferSummary(filledBytes: 320_000)
        let responses: [IPCResponse] = [
            .pong,
            .listening(ring: ring),
            .watching(ring: .init(filledBytes: 0)),
            .stopped(ring: ring),
            .ok,
            .okPath(path),
            .err("not listening"),
        ]
        for response in responses {
            XCTAssertEqual(IPCResponse.parse(line: response.line), response)
        }
    }

    func testStatusParseLegacyWithoutRingBytes() {
        XCTAssertEqual(
            IPCResponse.parse(line: "LISTENING"),
            .listening(ring: RingBufferSummary(filledBytes: 0))
        )
    }
}