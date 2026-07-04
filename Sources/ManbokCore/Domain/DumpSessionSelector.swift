import Foundation

// MARK: - CONTRACT (DumpSessionSelector)
//
// GUARANTEES
// - Parses CLI session targets: 1-based id (`1`), `last` (= newest), or `-N` (N sessions before newest).
// - `-1` = previous session (not Python “last element”).
// - Resolves against chronological session list (oldest first).
//
// DOES NOT
// - Talk to IPC or export WAV.

public enum DumpSessionSelector: Equatable, Sendable {
    case byId(Int)
    /// 0 = newest; 1 = one before newest (`-1` on CLI); 2 = two before (`-2`), etc.
    case fromEnd(offset: Int)
}

public enum DumpSessionSelectorError: Error, Equatable, Sendable {
    case invalidSyntax(String)
    case noSessions
    case unknownSession(id: Int)
    case offsetOutOfRange(offset: Int, sessionCount: Int)
}

public enum DumpSessionSelectorParser {
    public static func parse(_ text: String) -> Result<DumpSessionSelector, DumpSessionSelectorError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalidSyntax(text))
        }

        if trimmed == "last" {
            return .success(.fromEnd(offset: 0))
        }

        if let value = Int(trimmed) {
            if value >= 1 {
                return .success(.byId(value))
            }
            if value <= -1 {
                return .success(.fromEnd(offset: -value))
            }
        }

        return .failure(.invalidSyntax(text))
    }

    public static func resolve(
        _ selector: DumpSessionSelector,
        in sessions: [SessionSummary]
    ) -> Result<Int, DumpSessionSelectorError> {
        guard !sessions.isEmpty else {
            return .failure(.noSessions)
        }

        switch selector {
        case .byId(let id):
            guard sessions.contains(where: { $0.id == id }) else {
                return .failure(.unknownSession(id: id))
            }
            return .success(id)

        case .fromEnd(let offset):
            guard offset >= 0, offset < sessions.count else {
                return .failure(.offsetOutOfRange(offset: offset, sessionCount: sessions.count))
            }
            let position = sessions.count - 1 - offset
            return .success(sessions[position].id)
        }
    }
}