import Foundation

// MARK: - CONTRACT: IPCResponse
//
// GUARANTEES:
// - Serializes v1 NDJSON responses: one JSON object per line, each carrying "v":1 and a "type"
//   discriminator — pong, status, sessions, ok, ok_path, error.
// - `parse(line:)` round-trips wire forms produced by `jsonLine`.
//
// EXPECTS:
// - Dump success uses a file URL whose `.path` is the absolute filesystem path.
//
// FAILURE BEHAVIOR:
// - Unparseable JSON, or JSON with an unrecognized `type`, returns nil from `parse(line:)`.
//
// DOES NOT:
// - Perform I/O or choose dump paths (see DumpPaths).

/// Daemon replies sent over the Unix socket as NDJSON (one JSON object per line).
public enum IPCResponse: Equatable, Sendable {
    case pong
    case listening(ring: RingBufferSummary)
    case watching(ring: RingBufferSummary)
    case stopped(ring: RingBufferSummary)
    case sessions([SessionSummary])
    case ok
    case okPath(URL)
    case error(code: String, message: String)

    public var ring: RingBufferSummary? {
        switch self {
        case .listening(let ring), .watching(let ring), .stopped(let ring):
            return ring
        default:
            return nil
        }
    }

    /// Single-line NDJSON wire form, without trailing newline.
    public var jsonLine: String {
        let object: [String: Any]
        switch self {
        case .pong:
            object = ["v": 1, "type": "pong"]
        case .listening(let ring):
            object = Self.statusObject(phase: "listening", ring: ring)
        case .watching(let ring):
            object = Self.statusObject(phase: "watching", ring: ring)
        case .stopped(let ring):
            object = Self.statusObject(phase: "stopped", ring: ring)
        case .sessions(let list):
            object = ["v": 1, "type": "sessions", "sessions": list.map(Self.sessionObject)]
        case .ok:
            object = ["v": 1, "type": "ok"]
        case .okPath(let url):
            object = ["v": 1, "type": "ok_path", "path": url.path]
        case .error(let code, let message):
            object = ["v": 1, "type": "error", "code": code, "message": message]
        }
        return Self.serialize(object)
    }

    /// Parses a single NDJSON response line. Unknown `type` or invalid JSON returns nil.
    public static func parse(line: String) -> IPCResponse? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "pong":
            return .pong
        case "status":
            return parseStatus(object)
        case "sessions":
            return parseSessions(object)
        case "ok":
            return .ok
        case "ok_path":
            guard let path = object["path"] as? String, !path.isEmpty else { return nil }
            return .okPath(URL(fileURLWithPath: path))
        case "error":
            guard let code = object["code"] as? String,
                  let message = object["message"] as? String
            else { return nil }
            return .error(code: code, message: message)
        default:
            return nil
        }
    }

    private static func statusObject(phase: String, ring: RingBufferSummary) -> [String: Any] {
        [
            "v": 1,
            "type": "status",
            "phase": phase,
            "ring": ["filled_bytes": ring.filledBytes, "seconds": ring.bufferedSeconds],
        ]
    }

    private static func parseStatus(_ object: [String: Any]) -> IPCResponse? {
        guard let phase = object["phase"] as? String,
              let ringObject = object["ring"] as? [String: Any],
              let filledBytes = (ringObject["filled_bytes"] as? NSNumber)?.intValue
        else { return nil }
        let ring = RingBufferSummary(filledBytes: filledBytes)
        switch phase {
        case "listening": return .listening(ring: ring)
        case "watching": return .watching(ring: ring)
        case "stopped": return .stopped(ring: ring)
        default: return nil
        }
    }

    private static func sessionObject(_ summary: SessionSummary) -> [String: Any] {
        var object: [String: Any] = [
            "id": summary.id,
            "app": summary.appName ?? "Unknown",
            "bytes": summary.audioBytes,
            "dur_sec": summary.durationSeconds,
            "start_ago_sec": summary.startedSecondsAgo,
            "open": summary.isOpen ? 1 : 0,
        ]
        object["end_ago_sec"] = summary.endedSecondsAgo ?? NSNull()
        return object
    }

    private static func parseSessions(_ object: [String: Any]) -> IPCResponse? {
        guard let rawList = object["sessions"] as? [[String: Any]] else { return nil }
        let summaries = rawList.compactMap(parseSession)
        return .sessions(summaries)
    }

    private static func parseSession(_ item: [String: Any]) -> SessionSummary? {
        guard let idNumber = item["id"] as? NSNumber,
              let durNumber = item["dur_sec"] as? NSNumber,
              let startAgoNumber = item["start_ago_sec"] as? NSNumber
        else { return nil }

        let endAgo: TimeInterval?
        if let endNumber = item["end_ago_sec"] as? NSNumber {
            endAgo = endNumber.doubleValue
        } else {
            endAgo = nil
        }
        let isOpen = (item["open"] as? NSNumber)?.intValue == 1
        let audioBytes = (item["bytes"] as? NSNumber)?.intValue
            ?? Int(durNumber.doubleValue * Double(AudioFormat.bytesPerSecond))
        let appName = item["app"] as? String

        return SessionSummary(
            id: idNumber.uint64Value,
            audioBytes: audioBytes,
            durationSeconds: durNumber.doubleValue,
            startedSecondsAgo: startAgoNumber.doubleValue,
            endedSecondsAgo: endAgo,
            isOpen: isOpen,
            appName: appName
        )
    }

    private static func serialize(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{\"v\":1,\"type\":\"error\",\"code\":\"internal\",\"message\":\"serialization failure\"}"
        }
        return string
    }
}
