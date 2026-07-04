import Foundation

// MARK: - CONTRACT (DaemonPresentation)
//
// GUARANTEES
// - Selected once at daemon/CLI bootstrap; drives diagnostics + activity sinks.
// - Detached and foreground daemons: os.Logger only (Console.app).
// - CLI short commands: stderr mirror via separate bootstrap (see Diagnostics.install).
//
// DOES NOT
// - Encode capture policy (always-on vs opportunistic).

/// How the running process presents diagnostics and activity UI.
public enum DaemonPresentation: Sendable {
    /// Background daemon (stdio → /dev/null).
    case detached
    /// Daemon in this terminal: live meter on TTY, logs in Console only.
    case foregroundMeter
}