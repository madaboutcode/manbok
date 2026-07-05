import XCTest
@testable import ManbokCore

/// Spec enforcement tests for `docs/specs/interfaces/ipc.md`.
///
/// Scope: the Core wire-format boundary — `IPCCommand.parse`/`.wireLine` (request) and
/// `IPCResponse.jsonLine`/`.parse` (response). Socket transport concerns (framing over the
/// wire, the 4096-byte request cap) live in ManbokPlatform and are out of scope here — see
/// `UnixSocketIPCTests.swift`. Session ordering / stable-id monotonicity are enforced by
/// `SessionRegistry`, not by these IPC types — see `SessionRegistryTests.swift`.
final class IPCSpecTests: XCTestCase {

    // MARK: - §1 Transport — wire shape invariants

    private static let knownResponseTypes: Set<String> = [
        "pong", "status", "sessions", "ok", "ok_path", "error",
    ]

    func testSpec_S1_EveryResponseCarriesV1AndKnownTypeDiscriminator() throws {
        let responses: [IPCResponse] = [
            .pong,
            .listening(ring: RingBufferSummary(filledBytes: 32_000)),
            .watching(ring: RingBufferSummary(filledBytes: 0)),
            .stopped(ring: RingBufferSummary(filledBytes: 64_000)),
            .sessions([]),
            .sessions([
                SessionSummary(
                    id: 1, audioBytes: 32_000, durationSeconds: 1.0,
                    startedSecondsAgo: 10, endedSecondsAgo: nil, isOpen: true, appName: "Zoom"
                ),
            ]),
            .ok,
            .okPath(URL(fileURLWithPath: "/tmp/x.wav")),
            .error(code: "internal", message: "boom"),
        ]
        for response in responses {
            let data = Data(response.jsonLine.utf8)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["v"] as? Int, 1, "missing v:1 in \(response.jsonLine)")
            let type = try XCTUnwrap(object["type"] as? String, "missing type in \(response.jsonLine)")
            XCTAssertTrue(Self.knownResponseTypes.contains(type), "\(type) not in spec's closed discriminator set")
        }
    }

    // Spec §1: "Verb is case-insensitive (PING ≡ ping)."
    // Catches: a generator that only lowercases or only uppercases before matching.
    func testSpec_S1_VerbIsCaseInsensitiveForEveryVerb() {
        XCTAssertEqual(IPCCommand.parse(line: "PiNg"), .ping)
        XCTAssertEqual(IPCCommand.parse(line: "StAtUs"), .status)
        XCTAssertEqual(IPCCommand.parse(line: "SeSsIoNs"), .sessions)
        XCTAssertEqual(IPCCommand.parse(line: "sTOp"), .stop)
        XCTAssertEqual(IPCCommand.parse(line: "Dump"), .dump(minutes: nil, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "Dump Session 5"), .dump(minutes: nil, sessionId: 5))
        XCTAssertEqual(IPCCommand.parse(line: "dump session 5"), .dump(minutes: nil, sessionId: 5))
    }

    // Spec §7: "NDJSON framing: each response is exactly one JSON object followed by \n.
    // Multiple objects on one line ... MUST be rejected by the parser."
    // Catches: a parser that accepts the first object in a buffer and silently drops trailing
    // garbage instead of rejecting the whole line.
    func testSpec_S7_NDJSON_RejectsMultipleObjectsOnOneLine() {
        let concatenated = "{\"v\":1,\"type\":\"pong\"}{\"v\":1,\"type\":\"pong\"}"
        XCTAssertNil(IPCResponse.parse(line: concatenated), "parser must reject two objects on one line")
    }

    // MARK: - §2.1 PING

    // Catches: a request-side regression where PING stops round-tripping through wireLine.
    func testSpec_S21_PingRequestParsesAndRoundTrips() {
        XCTAssertEqual(IPCCommand.parse(line: "PING"), .ping)
        XCTAssertEqual(IPCCommand.parse(line: IPCCommand.ping.wireLine), .ping)
    }

    func testSpec_S21_PongResponseWireShapeIsExactlyVAndType() throws {
        let data = Data(IPCResponse.pong.jsonLine.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["type", "v"])
        XCTAssertEqual(object["type"] as? String, "pong")
    }

    // MARK: - §2.2 STATUS

    // Spec §2.2: phase is one of exactly three strings.
    // Catches: a fourth phase string slipping into the wire, or a typo like "listenning".
    func testSpec_S22_PhaseIsOneOfThreeDefinedStrings() throws {
        let cases: [(IPCResponse, String)] = [
            (.listening(ring: RingBufferSummary(filledBytes: 0)), "listening"),
            (.watching(ring: RingBufferSummary(filledBytes: 0)), "watching"),
            (.stopped(ring: RingBufferSummary(filledBytes: 0)), "stopped"),
        ]
        for (response, expectedPhase) in cases {
            let data = Data(response.jsonLine.utf8)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, "status")
            XCTAssertEqual(object["phase"] as? String, expectedPhase)
        }
    }

    // Spec §2.2: "ring.seconds — filled_bytes / 32000 (canonical 16 kHz mono s16le = 32000 bytes/sec)."
    // Catches: a wrong divisor (e.g. sample rate without the byte-width factor, or 16000).
    func testSpec_S22_RingSecondsIsFilledBytesDividedBy32000() throws {
        let ring = RingBufferSummary(filledBytes: 320_000) // spec example: 320000 / 32000 = 10.0
        let response = IPCResponse.listening(ring: ring)
        let data = Data(response.jsonLine.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ringObject = try XCTUnwrap(object["ring"] as? [String: Any])
        let seconds = try XCTUnwrap((ringObject["seconds"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(seconds, 10.0, accuracy: 0.0001)
    }

    // Spec §2.2: "ring.seconds ... May be 0.0."
    func testSpec_S22_RingSecondsMayBeZero() throws {
        let response = IPCResponse.watching(ring: RingBufferSummary(filledBytes: 0))
        let data = Data(response.jsonLine.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ringObject = try XCTUnwrap(object["ring"] as? [String: Any])
        XCTAssertEqual((ringObject["seconds"] as? NSNumber)?.doubleValue, 0.0)
        XCTAssertEqual((ringObject["filled_bytes"] as? NSNumber)?.intValue, 0)
    }

    // Spec §2.2: "ring.filled_bytes — non-negative integer."
    func testSpec_S22_RingFilledBytesNeverNegativeOnTheWire() throws {
        let ring = RingBufferSummary(filledBytes: -500) // domain type clamps; assert the wire agrees
        let response = IPCResponse.stopped(ring: ring)
        let data = Data(response.jsonLine.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ringObject = try XCTUnwrap(object["ring"] as? [String: Any])
        XCTAssertEqual((ringObject["filled_bytes"] as? NSNumber)?.intValue, 0)
    }

    // Catches: STATUS with a trailing argument being silently accepted instead of rejected.
    func testSpec_S22_StatusRejectsAnyArgument() {
        XCTAssertNil(IPCCommand.parse(line: "STATUS now"))
        XCTAssertNil(IPCCommand.parse(line: "STATUS 1"))
    }

    // MARK: - §2.3 SESSIONS

    func testSpec_S23_SessionsRequestRejectsAnyArgument() {
        XCTAssertNil(IPCCommand.parse(line: "SESSIONS 1"))
        XCTAssertNil(IPCCommand.parse(line: "SESSIONS all"))
    }

    // Spec §2.3 gives an exact field list for each session object.
    // Catches: a renamed/missing/extra key drifting the wire shape from the documented contract.
    func testSpec_S23_SessionObjectHasExactlySpecifiedKeys() throws {
        let summary = SessionSummary(
            id: 42, audioBytes: 32_000, durationSeconds: 1.0,
            startedSecondsAgo: 5, endedSecondsAgo: 2, isOpen: false, appName: "Zoom"
        )
        let data = Data(IPCResponse.sessions([summary]).jsonLine.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let item = try XCTUnwrap(list.first)
        XCTAssertEqual(
            Set(item.keys),
            Set(["id", "app", "bytes", "dur_sec", "start_ago_sec", "end_ago_sec", "open"])
        )
    }

    func testSpec_S23_OpenSessionHasNullEndAgoSecAndOpenFlagOne() throws {
        let summary = SessionSummary(
            id: 8, audioBytes: 16_000, durationSeconds: 1.0,
            startedSecondsAgo: 90, endedSecondsAgo: nil, isOpen: true, appName: "OBS"
        )
        let wire = IPCResponse.sessions([summary]).jsonLine
        let data = Data(wire.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let item = try XCTUnwrap(list.first)
        XCTAssertTrue(item["end_ago_sec"] is NSNull)
        XCTAssertEqual((item["open"] as? NSNumber)?.intValue, 1)
    }

    func testSpec_S23_ClosedSessionHasNumericEndAgoSecAndOpenFlagZero() throws {
        let summary = SessionSummary(
            id: 9, audioBytes: 16_000, durationSeconds: 1.0,
            startedSecondsAgo: 120, endedSecondsAgo: 30, isOpen: false, appName: "Zoom"
        )
        let wire = IPCResponse.sessions([summary]).jsonLine
        let data = Data(wire.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let item = try XCTUnwrap(list.first)
        XCTAssertEqual((item["end_ago_sec"] as? NSNumber)?.doubleValue, 30.0)
        XCTAssertEqual((item["open"] as? NSNumber)?.intValue, 0)
    }

    // Spec §2.3: "app — ... always present; never null ... Always non-empty."
    // Adversarial: SessionSummary.appName is an Optional<String> with a nil default, but
    // IPCResponse.sessionObject serializes `summary.appName ?? ""`. A nil appName therefore
    // produces "app":"" on the wire — violating "Always non-empty." This test is expected to
    // FAIL against the current implementation; that failure is a bug report against
    // IPCResponse.sessionObject, not a test to weaken.
    func testSpec_S23_AppNameMustNeverBeEmptyStringOnTheWire() throws {
        let summary = SessionSummary(
            id: 1, audioBytes: 32_000, durationSeconds: 1.0,
            startedSecondsAgo: 1, endedSecondsAgo: nil, isOpen: true, appName: nil
        )
        let wire = IPCResponse.sessions([summary]).jsonLine
        let data = Data(wire.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let item = try XCTUnwrap(list.first)
        let app = try XCTUnwrap(item["app"] as? String)
        XCTAssertFalse(app.isEmpty, "spec §2.3 requires app to always be non-empty")
    }

    // Spec §2.3: id is UInt64 — the full 64-bit range must survive the JSON round trip without
    // precision loss. JSON numbers can silently degrade to Double (53-bit mantissa) in transit.
    // Catches: an id above 2^53 losing precision when boxed through NSNumber/JSONSerialization.
    func testSpec_S23_LargeUInt64IdsRoundTripWithoutPrecisionLoss() throws {
        let ids: [UInt64] = [UInt64.max, 9_007_199_254_740_993] // 2^53 + 1, first non-exact Double
        for id in ids {
            let summary = SessionSummary(
                id: id, audioBytes: 0, durationSeconds: 0,
                startedSecondsAgo: 0, endedSecondsAgo: nil, isOpen: true, appName: "X"
            )
            let wire = IPCResponse.sessions([summary]).jsonLine
            guard case .sessions(let parsed) = IPCResponse.parse(line: wire) else {
                return XCTFail("expected sessions response for id \(id)")
            }
            XCTAssertEqual(parsed.first?.id, id, "UInt64 id \(id) did not round-trip exactly")
        }
    }

    func testSpec_S23_SessionsEmptyListRoundTrips() {
        let wire = IPCResponse.sessions([]).jsonLine
        guard case .sessions(let list) = IPCResponse.parse(line: wire) else {
            return XCTFail("expected sessions response")
        }
        XCTAssertTrue(list.isEmpty)
    }

    // MARK: - §2.4 STOP

    func testSpec_S24_StopRequestParsesAndRejectsArguments() {
        XCTAssertEqual(IPCCommand.parse(line: "STOP"), .stop)
        XCTAssertNil(IPCCommand.parse(line: "STOP now"))
    }

    func testSpec_S24_OkResponseWireShapeIsExactlyVAndType() throws {
        let data = Data(IPCResponse.ok.jsonLine.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["type", "v"])
        XCTAssertEqual(object["type"] as? String, "ok")
    }

    // MARK: - §2.5 DUMP

    func testSpec_S25_DumpBareParsesAsNilMinutesNilSessionId() {
        XCTAssertEqual(IPCCommand.parse(line: "DUMP"), .dump(minutes: nil, sessionId: nil))
    }

    // Spec §2.5: "DUMP <minutes> ... N is a non-negative integer."
    func testSpec_S25_DumpMinutesAcceptsNonNegativeRejectsNegative() {
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 0"), .dump(minutes: 0, sessionId: nil))
        XCTAssertEqual(IPCCommand.parse(line: "DUMP 5"), .dump(minutes: 5, sessionId: nil))
        XCTAssertNil(IPCCommand.parse(line: "DUMP -1"), "spec requires non-negative N")
    }

    // Spec §7: "Send DUMP x → bad_command."
    func testSpec_S25_DumpRejectsNonNumericMinutes() {
        XCTAssertNil(IPCCommand.parse(line: "DUMP x"))
    }

    // Spec §7: "Send DUMP SESSION 0 → bad_command (id must be ≥ 1)."
    func testSpec_S25_DumpSessionRejectsIdZero() {
        XCTAssertNil(IPCCommand.parse(line: "DUMP SESSION 0"))
    }

    func testSpec_S25_DumpSessionAcceptsIdOne() {
        XCTAssertEqual(IPCCommand.parse(line: "DUMP SESSION 1"), .dump(minutes: nil, sessionId: 1))
    }

    // Spec §2.5: "<stableId> is a UInt64" — the boundary of that type must be honored exactly.
    func testSpec_S25_DumpSessionAcceptsUInt64MaxRejectsOneAboveMax() {
        XCTAssertEqual(
            IPCCommand.parse(line: "DUMP SESSION 18446744073709551615"),
            .dump(minutes: nil, sessionId: UInt64.max)
        )
        XCTAssertNil(
            IPCCommand.parse(line: "DUMP SESSION 18446744073709551616"),
            "one past UInt64.max must not silently wrap or truncate"
        )
    }

    func testSpec_S25_DumpSessionRejectsNonNumericId() {
        XCTAssertNil(IPCCommand.parse(line: "DUMP SESSION x"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP SESSION"))
    }

    // Spec §7 implies argument-syntax errors are bad_command; malformed multi-token DUMP forms
    // must not be coerced into a partial match.
    func testSpec_S25_DumpRejectsMalformedMultiTokenForms() {
        XCTAssertNil(IPCCommand.parse(line: "DUMP 5 6"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP 5 extra"))
        XCTAssertNil(IPCCommand.parse(line: "DUMP SESSION 5 extra"))
    }

    func testSpec_S25_OkPathWireShapeCarriesAbsolutePath() throws {
        let path = "/absolute/path/to/manbok-zoom-20260705-143022.wav"
        let response = IPCResponse.okPath(URL(fileURLWithPath: path))
        let data = Data(response.jsonLine.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "ok_path")
        XCTAssertEqual(object["path"] as? String, path)
    }

    func testSpec_S25_OkPathParseRejectsEmptyPath() {
        XCTAssertNil(IPCResponse.parse(line: "{\"v\":1,\"type\":\"ok_path\",\"path\":\"\"}"))
    }

    // MARK: - §3 Error responses

    func testSpec_S3_ErrorWireShapeHasCodeAndMessage() throws {
        let response = IPCResponse.error(code: "empty_buffer", message: "ring buffer is empty (watching)")
        let data = Data(response.jsonLine.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "error")
        XCTAssertEqual(object["code"] as? String, "empty_buffer")
        XCTAssertEqual(object["message"] as? String, "ring buffer is empty (watching)")
    }

    // Spec §3 lists 6 stable codes. Consumers match on `code`, so each must round-trip verbatim.
    func testSpec_S3_AllDefinedErrorCodesRoundTripVerbatim() {
        let definedCodes = ["bad_command", "internal", "not_listening", "empty_buffer", "session_not_found", "dump_io"]
        for code in definedCodes {
            let response = IPCResponse.error(code: code, message: "context for \(code)")
            XCTAssertEqual(IPCResponse.parse(line: response.jsonLine), response, "code \(code) failed to round-trip")
        }
    }

    // Spec §3: "Forward compatibility: consumers MUST ignore unknown error codes ... do not crash."
    func testSpec_S3_UnknownErrorCodeParsesWithoutCrashing() {
        let wire = "{\"v\":1,\"type\":\"error\",\"code\":\"a_future_code_v3\",\"message\":\"new failure mode\"}"
        XCTAssertEqual(IPCResponse.parse(line: wire), .error(code: "a_future_code_v3", message: "new failure mode"))
    }

    func testSpec_S3_ErrorParseRejectsMissingCode() {
        XCTAssertNil(IPCResponse.parse(line: "{\"v\":1,\"type\":\"error\",\"message\":\"boom\"}"))
    }

    func testSpec_S3_ErrorParseRejectsMissingMessage() {
        XCTAssertNil(IPCResponse.parse(line: "{\"v\":1,\"type\":\"error\",\"code\":\"internal\"}"))
    }

    // MARK: - §5 Versioning — additive-field forward compatibility

    // Spec §5: "Within v:1, fields may be ADDED to existing response types ...
    // Consumers MUST ignore unknown fields."
    // Catches: a parser that fails closed the moment it sees an unrecognized key, for every
    // response type — not just the trivial `pong` case already covered in IPCTests.swift.
    func testSpec_S5_UnknownFieldIgnoredOnStatusType() {
        let wire = "{\"v\":1,\"type\":\"status\",\"phase\":\"watching\",\"ring\":{\"filled_bytes\":0,\"seconds\":0.0},\"future_field\":true}"
        XCTAssertEqual(IPCResponse.parse(line: wire), .watching(ring: RingBufferSummary(filledBytes: 0)))
    }

    func testSpec_S5_UnknownFieldIgnoredOnSessionsType() {
        let wire = "{\"v\":1,\"type\":\"sessions\",\"sessions\":[],\"future_field\":\"x\"}"
        guard case .sessions(let list) = IPCResponse.parse(line: wire) else {
            return XCTFail("expected sessions response despite unknown top-level field")
        }
        XCTAssertTrue(list.isEmpty)
    }

    // Spec §7: "Send a response with an unknown type → consumer must not crash."
    func testSpec_S7_UnknownResponseTypeParsesToNilWithoutCrashing() {
        XCTAssertNil(IPCResponse.parse(line: "{\"v\":1,\"type\":\"teleport\"}"))
    }
}
