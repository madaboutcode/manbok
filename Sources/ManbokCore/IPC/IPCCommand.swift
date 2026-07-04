import Foundation

// MARK: - CONTRACT: IPCCommand
//
// GUARANTEES:
// - Parses UTF-8 line commands: PING, STATUS, SESSIONS, STOP, DUMP [minutes|SESSION id].
// - `DUMP` with no argument → dump(all) via `minutes: nil`.
// - `DUMP N` where N is a non-negative integer → dump(last N minutes).
// - Unknown verbs or malformed lines return nil from `parse(line:)`.
//
// EXPECTS:
// - One command per line; trailing newline/whitespace is trimmed.
//
// FAILURE BEHAVIOR:
// - Invalid input → nil (caller responds with ERR over IPC).
//
// DOES NOT:
// - Open sockets, execute use cases, or serialize responses (see IPCResponse).

/// Daemon control commands received over the Unix socket line protocol.
public enum IPCCommand: Equatable, Sendable {
    case ping
    case status
    case sessions
    case stop
    case dump(minutes: Int?, sessionId: Int?)

    /// Wire form without trailing newline (caller adds `\n` when sending).
    public var wireLine: String {
        switch self {
        case .ping:
            return "PING"
        case .status:
            return "STATUS"
        case .sessions:
            return "SESSIONS"
        case .stop:
            return "STOP"
        case .dump(let minutes, let sessionId):
            if let sessionId {
                return "DUMP SESSION \(sessionId)"
            }
            if let minutes {
                return "DUMP \(minutes)"
            }
            return "DUMP"
        }
    }

    /// Parses a single command line (whitespace-trimmed).
    public static func parse(line: String) -> IPCCommand? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let verb = parts.first else { return nil }

        switch verb.uppercased() {
        case "PING":
            return parts.count == 1 ? .ping : nil
        case "STATUS":
            return parts.count == 1 ? .status : nil
        case "SESSIONS":
            return parts.count == 1 ? .sessions : nil
        case "STOP":
            return parts.count == 1 ? .stop : nil
        case "DUMP":
            if parts.count == 3, parts[1].uppercased() == "SESSION", let id = Int(parts[2]), id >= 1 {
                return .dump(minutes: nil, sessionId: id)
            }
            switch parts.count {
            case 1:
                return .dump(minutes: nil, sessionId: nil)
            case 2:
                guard let minutes = Int(parts[1]), minutes >= 0 else { return nil }
                return .dump(minutes: minutes, sessionId: nil)
            default:
                return nil
            }
        default:
            return nil
        }
    }
}