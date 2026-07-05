import Foundation

// MARK: - CONTRACT (AppLog)
//
// GUARANTEES
// - Routes categories through Diagnostics.install sink.
// - App target uses OSLogOnlyDiagnostics; CLI uses OSLogAndStderrDiagnostics.
// - `.notice` maps to Logger.notice (persisted by macOS unified logging).
// - `.info` maps to Logger.info (NOT persisted — visible only with --info flag or live streaming).
// - `.debug` maps to Logger.debug (NOT persisted); stderr mirror only when verbose is true.
//
// DOES NOT
// - Write log files, use print(), or emit diagnostics on stdout.

/// Category-tagged diagnostics facade (sink configured at bootstrap).
public struct AppLog {
    public static let subsystem = "ai.manbok.app"

    /// When true, CLI sink also mirrors `.debug` to stderr.
    public static var verbose = false

    public enum Category: String {
        case cli
        case daemon
        case capture
        case app
        case settings
        case export
        case ipc
    }

    private let category: Category

    public init(category: Category) {
        self.category = category
    }

    public func notice(_ message: String) {
        Diagnostics.emit { $0.notice(category: category, message) }
    }

    public func info(_ message: String) {
        Diagnostics.emit { $0.info(category: category, message) }
    }

    public func warning(_ message: String) {
        Diagnostics.emit { $0.warning(category: category, message) }
    }

    public func error(_ message: String) {
        Diagnostics.emit { $0.error(category: category, message) }
    }

    public func debug(_ message: String) {
        Diagnostics.emit { $0.debug(category: category, message) }
    }
}