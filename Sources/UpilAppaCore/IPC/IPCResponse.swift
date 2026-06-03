import Foundation

// MARK: - CONTRACT: IPCResponse
//
// GUARANTEES:
// - Serializes v1 responses: PONG, LISTENING, WATCHING, STOPPED, OK, OK path=<absolute-path>, ERR <message>.
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
    case listening
    case watching
    case stopped
    case ok
    case okPath(URL)
    case err(String)

    /// Single-line wire form without trailing newline.
    public var line: String {
        switch self {
        case .pong:
            return "PONG"
        case .listening:
            return "LISTENING"
        case .watching:
            return "WATCHING"
        case .stopped:
            return "STOPPED"
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
        if trimmed == "LISTENING" { return .listening }
        if trimmed == "WATCHING" { return .watching }
        if trimmed == "STOPPED" { return .stopped }
        if trimmed == "OK" { return .ok }

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
}