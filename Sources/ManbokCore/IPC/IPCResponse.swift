import Foundation

// MARK: - CONTRACT: IPCResponse
//
// GUARANTEES:
// - Serializes v1 responses: PONG, LISTENING|WATCHING|STOPPED [ring_bytes=N], SESSIONS …, OK, OK path=…, ERR …
// - `parse(line:)` round-trips wire forms produced by `line`.
//
// EXPECTS:
// - Dump success uses a file URL whose `.path` is the absolute filesystem path.
//
// FAILURE BEHAVIOR:
// - Unrecognized response lines return nil from `parse(line:)`.
//
// DOES NOT:
// - Perform I/O or choose dump paths (see ListenerService / DumpPaths).

/// Daemon replies sent over the Unix socket line protocol.
public enum IPCResponse: Equatable, Sendable {
    case pong
    case listening(ring: RingBufferSummary)
    case watching(ring: RingBufferSummary)
    case stopped(ring: RingBufferSummary)
    case sessions([SessionSummary])
    case ok
    case okPath(URL)
    case err(String)

    public var ring: RingBufferSummary? {
        switch self {
        case .listening(let ring), .watching(let ring), .stopped(let ring):
            return ring
        default:
            return nil
        }
    }

    /// Single-line wire form without trailing newline.
    public var line: String {
        switch self {
        case .pong:
            return "PONG"
        case .listening(let ring):
            return Self.statusWire(verb: "LISTENING", ring: ring)
        case .watching(let ring):
            return Self.statusWire(verb: "WATCHING", ring: ring)
        case .stopped(let ring):
            return Self.statusWire(verb: "STOPPED", ring: ring)
        case .sessions(let list):
            return Self.sessionsWire(list)
        case .ok:
            return "OK"
        case .okPath(let url):
            return "OK path=\(url.path)"
        case .err(let message):
            return "ERR \(message)"
        }
    }

    /// Parses a single response line (whitespace-trimmed).
    public static func parse(line: String) -> IPCResponse? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "PONG" { return .pong }
        if trimmed == "OK" { return .ok }

        if let status = parseStatusLine(trimmed) { return status }
        if let sessions = parseSessionsLine(trimmed) { return sessions }

        if trimmed.hasPrefix("OK path=") {
            let path = String(trimmed.dropFirst("OK path=".count))
            guard !path.isEmpty else { return nil }
            return .okPath(URL(fileURLWithPath: path))
        }

        if trimmed.hasPrefix("ERR ") {
            let message = String(trimmed.dropFirst(4))
            return .err(message)
        }

        return nil
    }

    private static func statusWire(verb: String, ring: RingBufferSummary) -> String {
        "\(verb) \(ring.ipcSuffix)"
    }

    private static func sessionsWire(_ list: [SessionSummary]) -> String {
        var parts = ["SESSIONS", "count=\(list.count)"]
        for summary in list {
            parts.append("s\(summary.id)=\(summary.ipcToken)")
        }
        return parts.joined(separator: " ")
    }

    private static func parseSessionsLine(_ trimmed: String) -> IPCResponse? {
        guard trimmed.hasPrefix("SESSIONS ") else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        var summaries: [SessionSummary] = []

        for part in parts.dropFirst() {
            let token = String(part)
            if token.hasPrefix("count=") { continue }
            guard token.hasPrefix("s"), let summary = parseSessionToken(token) else { continue }
            summaries.append(summary)
        }

        summaries.sort { $0.id < $1.id }
        return .sessions(summaries)
    }

    private static func parseSessionToken(_ token: String) -> SessionSummary? {
        guard let eq = token.firstIndex(of: "=") else { return nil }
        let payload = String(token[token.index(after: eq)...])
        var fields: [String: String] = [:]
        for piece in payload.split(separator: ",", omittingEmptySubsequences: false) {
            let pieceStr = String(piece)
            guard let sep = pieceStr.firstIndex(of: ":") else { continue }
            let key = String(pieceStr[..<sep])
            let value = String(pieceStr[pieceStr.index(after: sep)...])
            fields[key] = value
        }

        guard let id = Int(fields["id"] ?? ""),
              let dur = Double(fields["dur_sec"] ?? ""),
              let startAgo = TimeInterval(fields["start_ago_sec"] ?? "")
        else { return nil }

        let endAgo: TimeInterval?
        if let endRaw = fields["end_ago_sec"], !endRaw.isEmpty {
            endAgo = TimeInterval(endRaw)
        } else {
            endAgo = nil
        }
        let isOpen = (fields["open"] ?? "0") == "1"
        let audioBytes = Int(fields["bytes"] ?? "") ?? Int(dur * Double(AudioFormat.bytesPerSecond))
        let appName = fields["app"]

        return SessionSummary(
            id: id,
            audioBytes: audioBytes,
            durationSeconds: dur,
            startedSecondsAgo: startAgo,
            endedSecondsAgo: endAgo,
            isOpen: isOpen,
            appName: appName
        )
    }

    private static func parseStatusLine(_ trimmed: String) -> IPCResponse? {
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let verb = parts.first.map(String.init)?.uppercased() else { return nil }

        var ringBytes = 0
        for part in parts.dropFirst() {
            let token = String(part)
            if token.hasPrefix("ring_bytes=") {
                ringBytes = Int(token.dropFirst("ring_bytes=".count)) ?? 0
            }
        }
        let ring = RingBufferSummary(filledBytes: ringBytes)

        switch verb {
        case "LISTENING":
            return .listening(ring: ring)
        case "WATCHING":
            return .watching(ring: ring)
        case "STOPPED":
            return .stopped(ring: ring)
        default:
            return nil
        }
    }
}