import Foundation

// MARK: - CONTRACT: ListenerError
//
// GUARANTEES:
// - Stable IPC error codes (see docs/specs/interfaces/ipc.md §3).
//
// DOES NOT:
// - Parse CLI flags, launch GUI apps, or import platform frameworks.

public enum ListenerError: Error, Equatable, Sendable {
    case notListening
    case emptyBuffer
    case sessionNotFound(UInt64)

    public var message: String {
        switch self {
        case .notListening:
            return "not listening"
        case .emptyBuffer:
            return "ring buffer is empty"
        case .sessionNotFound(let id):
            return "session \(id) not found"
        }
    }

    /// Stable IPC error code (see docs/specs/interfaces/ipc.md §3).
    public var code: String {
        switch self {
        case .notListening: return "not_listening"
        case .emptyBuffer: return "empty_buffer"
        case .sessionNotFound: return "session_not_found"
        }
    }
}
