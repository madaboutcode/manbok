import Foundation

// MARK: - CONTRACT (AppLog)
//
// GUARANTEES
// - Routes categories cli | daemon | capture through Diagnostics.install sink.
// - Daemon bootstrap uses OSLogOnlyDiagnostics; CLI uses OSLogAndStderrDiagnostics.
// - `.debug` stderr mirror only when sink supports it and AppLog.verbose is true.
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
    }

    private let category: Category

    public init(category: Category) {
        self.category = category
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