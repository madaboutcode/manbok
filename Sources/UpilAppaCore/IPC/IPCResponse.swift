import Foundation

// MARK: - CONTRACT: IPCResponse
//
// GUARANTEES:
// - Serializes v1 responses: PONG, LISTENING|WATCHING|STOPPED [ring_bytes=N], OK, OK path=…, ERR …
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