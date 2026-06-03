import XCTest
@testable import UpilAppaCore

final class IPCTests: XCTestCase {
    // MARK: - Command parse

    func testParsePingStatusStop() {
        XCTAssertEqual(IPCCommand.parse(line: "PING"), .ping)
        XCTAssertEqual(IPCCommand.parse(line: "ping"), .ping)
        XCTAssertEqual(IPCCommand.parse(line: "STATUS"), .status)
        XCTAssertEqual(IPCCommand.parse(line: "STOP"), .stop)
        XCTAssertNil(IPCCommand.parse(line: "PING extra"))
        XCTAssertNil(IPCCommand.parse(line: ""))
        XCTAssertNil(IPCCommand.parse(line: "   "))
        XCTAssertNil(IPCCommand.parse(line: "NOPE"))
    }

    func testParseSessionsCommand() {
        XCTAssertEqual(IPCCommand.parse(line: "SESSIONS"), .sessions)
        XCTAssertEqual(IPCCommand.parse(line: "sessions\n"), .sessions)
        XCTAssertNil(IPCCommand.parse(line: "SESSIONS 1"))
    }

    func testParseDumpWithMinutes() {
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 3"), .dump(minutes: 3, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 3\n"), .dump(minutes: 3, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "dump 5"), .dump(minutes: 5, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP"), .dump(minutes: nil, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP SESSION 2"), .dump(minutes: nil, sessionId: 2))
        XCTAssertEqual(IPCCommand.parse(line: "dump session 9"), .dump(minutes: nil, sessionId: 9))
        XCTAssertNil(IPCCommand.parse(line: "DUMP x"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP 3 extra"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP SESSION 0"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP SESSION"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP SESSION x"))
    }

    func testCommandWireLineRoundTrip() {
        let commands: [IPCCommand] = [
            .ping,
            .status,
            .sessions,
            .stop,
            .dump(minutes: nil, sessionId: nil),
            .dump(minutes: 5, sessionId: nil),
            .dump(minutes: nil, sessionId: 2),
        ]
        for command in commands {
            XCTAssertEqual(IPCCommand.parse(line: command.wireLine), command, "round-trip \(command)")
        }
    }

    // MARK: - Response parse / serialize

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
            XCTAssertEqual(IPCResponse.parse(line: response.line), response, "round-trip \(response.line)")
        }
    }

    func testStatusParseLegacyWithoutRingBytes() {
        XCTAssertEqual(
            IPCResponse.parse(line: "LISTENING"),
            .listening(ring: RingBufferSummary(filledBytes: 0))
        )
        XCTAssertEqual(
            IPCResponse.parse(line: "WATCHING ring_bytes=0"),
            .watching(ring: RingBufferSummary(filledBytes: 0))
        )
    }

    func testStatusParseWithRingBytes() {
        XCTAssertEqual(
            IPCResponse.parse(line: "LISTENING ring_bytes=192000"),
            .listening(ring: RingBufferSummary(filledBytes: 192_000))
        )
        let wire = IPCResponse.listening(ring: RingBufferSummary(filledBytes: 48_000)).line
        XCTAssertEqual(IPCResponse.parse(line: wire), .listening(ring: RingBufferSummary(filledBytes: 48_000)))
    }

    func testSessionsResponseEmpty() {
        let wire = IPCResponse.sessions([]).line
        XCTAssertEqual(wire, "SESSIONS count=0")
        guard case .sessions(let list) = IPCResponse.parse(line: wire) else {
            return XCTFail("expected sessions")
        }
        XCTAssertTrue(list.isEmpty)
    }

    func testSessionsResponseRoundTripMultiple() {
        let list = [
            SessionSummary(
                id: 1,
                audioBytes: 32_000,
                durationSeconds: 2.0,
                startedSecondsAgo: 600,
                endedSecondsAgo: 120,
                isOpen: false
            ),
            SessionSummary(
                id: 2,
                audioBytes: 16_000,
                durationSeconds: 1.0,
                startedSecondsAgo: 90,
                endedSecondsAgo: nil,
                isOpen: true
            ),
        ]
        let wire = IPCResponse.sessions(list).line
        XCTAssertTrue(wire.contains("s1="))
        XCTAssertTrue(wire.contains("s2="))
        XCTAssertTrue(wire.contains("open:1"))

        guard case .sessions(let parsed) = IPCResponse.parse(line: wire) else {
            return XCTFail("expected sessions response")
        }
        XCTAssertEqual(parsed, list)
    }

    func testSessionsResponseSortsById() {
        let wire = "SESSIONS count=2 s2=id:2,bytes:1000,dur_sec:1.0,start_ago_sec:10,end_ago_sec:5,open:0 s1=id:1,bytes:2000,dur_sec:2.0,start_ago_sec:20,end_ago_sec:15,open:0"
        guard case .sessions(let parsed) = IPCResponse.parse(line: wire) else {
            return XCTFail("expected sessions")
        }
        XCTAssertEqual(parsed.map(\.id), [1, 2])
    }

    func testResponseParseRejectsInvalid() {
        XCTAssertNil(IPCResponse.parse(line: ""))
        XCTAssertNil(IPCResponse.parse(line: "OK path="))
        XCTAssertNil(IPCResponse.parse(line: "SESSIONS"))
        XCTAssertNil(IPCResponse.parse(line: "MAYBE"))
    }

    func testSessionsResponseSkipsMalformedTokens() {
        guard case .sessions(let list) = IPCResponse.parse(line: "SESSIONS count=1 s1=not-a-token") else {
            return XCTFail("expected sessions envelope")
        }
        XCTAssertTrue(list.isEmpty)
    }

    func testErrMessagePreservesSpaces() {
        let message = "ring buffer is empty (watching)"
        XCTAssertEqual(IPCResponse.parse(line: "ERR \(message)"), .err(message))
    }

    func testParseDumpZeroMinutes() {
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 0"), .dump(minutes: 0, sessionId: nil))
    }

    func testStoppedStatusRoundTrip() {
        let ring = RingBufferSummary(filledBytes: 96_000)
        let response = IPCResponse.stopped(ring: ring)
        XCTAssertEqual(IPCResponse.parse(line: response.line), response)
    }
}