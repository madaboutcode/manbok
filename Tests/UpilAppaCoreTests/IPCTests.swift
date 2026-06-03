import XCTest
@testable import UpilAppaCore

final class IPCTests: XCTestCase {
    func testParseDumpWithMinutes() {
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 3"), .dump(minutes: 3, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 3\n"), .dump(minutes: 3, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "dump 5"), .dump(minutes: 5, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP"), .dump(minutes: nil, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP SESSION 2"), .dump(minutes: nil, sessionId: 2))
        XCTAssertNil(IPCCommand.parse(line: "DUMP x"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP 3 extra"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP SESSION 0"))
    }

    func testParseSessionsCommand() {
        XCTAssertEqual(IPCCommand.parse(line: "SESSIONS"), .sessions)
    }

    func testCommandWireLineRoundTrip() {
        XCTAssertEqual(IPCCommand.dump(minutes: 3, sessionId: nil).wireLine, "DUMP 3")
        XCTAssertEqual(
            IPCCommand.parse(line: IPCCommand.dump(minutes: 3, sessionId: nil).wireLine),
            .dump(minutes: 3, sessionId: nil)
        )
        XCTAssertEqual(IPCCommand.dump(minutes: nil, sessionId: 2).wireLine, "DUMP SESSION 2")
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