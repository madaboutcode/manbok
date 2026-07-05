import XCTest
@testable import ManbokCore

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
        let path = URL(fileURLWithPath: "/tmp/manbok-test.wav")
        let ring = RingBufferSummary(filledBytes: 320_000)
        let responses: [IPCResponse] = [
            .pong,
            .listening(ring: ring),
            .watching(ring: .init(filledBytes: 0)),
            .stopped(ring: ring),
            .ok,
            .okPath(path),
            .error(code: "not_listening", message: "not listening"),
        ]
        for response in responses {
            XCTAssertEqual(IPCResponse.parse(line: response.jsonLine), response, "round-trip \(response.jsonLine)")
        }
    }

    func testEveryResponseCarriesVersionAndTypeDiscriminator() {
        let responses: [IPCResponse] = [
            .pong,
            .listening(ring: RingBufferSummary(filledBytes: 0)),
            .watching(ring: RingBufferSummary(filledBytes: 0)),
            .stopped(ring: RingBufferSummary(filledBytes: 0)),
            .sessions([]),
            .ok,
            .okPath(URL(fileURLWithPath: "/tmp/x.wav")),
            .error(code: "internal", message: "boom"),
        ]
        for response in responses {
            let data = Data(response.jsonLine.utf8)
            let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(object["v"] as? Int, 1, "\(response.jsonLine) missing v:1")
            XCTAssertNotNil(object["type"] as? String, "\(response.jsonLine) missing type")
        }
    }

    func testStatusWireShape() {
        let ring = RingBufferSummary(filledBytes: 192_000)
        let response = IPCResponse.listening(ring: ring)
        let data = Data(response.jsonLine.utf8)
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["type"] as? String, "status")
        XCTAssertEqual(object["phase"] as? String, "listening")
        let ringObject = object["ring"] as! [String: Any]
        XCTAssertEqual((ringObject["filled_bytes"] as? NSNumber)?.intValue, 192_000)
        XCTAssertEqual((ringObject["seconds"] as? NSNumber)?.doubleValue ?? -1, 6.0, accuracy: 0.001)
    }

    func testSessionsResponseEmpty() {
        let wire = IPCResponse.sessions([]).jsonLine
        guard case .sessions(let list) = IPCResponse.parse(line: wire) else {
            return XCTFail("expected sessions")
        }
        XCTAssertTrue(list.isEmpty)
    }

    func testSessionsResponseRoundTripMultiple() {
        let list = [
            SessionSummary(
                id: 7,
                audioBytes: 32_000,
                durationSeconds: 2.0,
                startedSecondsAgo: 600,
                endedSecondsAgo: 120,
                isOpen: false,
                appName: "Zoom"
            ),
            SessionSummary(
                id: 8,
                audioBytes: 16_000,
                durationSeconds: 1.0,
                startedSecondsAgo: 90,
                endedSecondsAgo: nil,
                isOpen: true,
                appName: "OBS"
            ),
        ]
        let wire = IPCResponse.sessions(list).jsonLine
        XCTAssertTrue(wire.contains("\"id\":7"))
        XCTAssertTrue(wire.contains("\"id\":8"))
        XCTAssertTrue(wire.contains("\"open\":1"))

        guard case .sessions(let parsed) = IPCResponse.parse(line: wire) else {
            return XCTFail("expected sessions response")
        }
        XCTAssertEqual(parsed, list)
    }

    func testSessionsResponseNullEndAgoForOpenSession() {
        let open = SessionSummary(
            id: 8,
            audioBytes: 16_000,
            durationSeconds: 1.0,
            startedSecondsAgo: 90,
            endedSecondsAgo: nil,
            isOpen: true,
            appName: "OBS"
        )
        let wire = IPCResponse.sessions([open]).jsonLine
        XCTAssertTrue(wire.contains("\"end_ago_sec\":null"))
    }

    func testResponseParseRejectsInvalid() {
        XCTAssertNil(IPCResponse.parse(line: ""))
        XCTAssertNil(IPCResponse.parse(line: "not json"))
        XCTAssertNil(IPCResponse.parse(line: "{\"v\":1}"))
        XCTAssertNil(IPCResponse.parse(line: "{\"v\":1,\"type\":\"maybe\"}"))
        XCTAssertNil(IPCResponse.parse(line: "{\"v\":1,\"type\":\"ok_path\"}"))
    }

    func testParseIgnoresExtraFieldsForwardCompat() {
        let wire = "{\"v\":1,\"type\":\"pong\",\"extra\":\"field\"}"
        XCTAssertEqual(IPCResponse.parse(line: wire), .pong)
    }

    func testParseMissingVersionStillAccepted() {
        // Missing `v` is OK for forward compat on parse; only serialize guarantees it.
        let wire = "{\"type\":\"ok\"}"
        XCTAssertEqual(IPCResponse.parse(line: wire), .ok)
    }

    func testErrorMessagePreservesSpacesAndCode() {
        let response = IPCResponse.error(code: "empty_buffer", message: "ring buffer is empty (watching)")
        let wire = response.jsonLine
        XCTAssertEqual(IPCResponse.parse(line: wire), response)
    }

    func testParseDumpZeroMinutes() {
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 0"), .dump(minutes: 0, sessionId: nil))
    }

    func testStoppedStatusRoundTrip() {
        let ring = RingBufferSummary(filledBytes: 96_000)
        let response = IPCResponse.stopped(ring: ring)
        XCTAssertEqual(IPCResponse.parse(line: response.jsonLine), response)
    }
}
