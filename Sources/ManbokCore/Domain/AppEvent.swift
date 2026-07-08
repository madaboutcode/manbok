import Foundation

/// One app process arriving at or departing from the mic, derived by CaptureSupervisor's
/// poll-diff logic. Pure value type — no framework dependency.
public enum AppEvent: Equatable {
    case arrived(bundleID: String, pid: pid_t)
    case departed(bundleID: String)
}
