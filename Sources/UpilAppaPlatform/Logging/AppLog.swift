import Foundation
import os

// MARK: - CONTRACT (AppLog)
//
// GUARANTEES
// - Uses os.Logger with subsystem `ai.upil.appa` and categories cli | daemon | capture.
// - `.info`, `.warning`, and `.error` are recorded in Logger and mirrored to stderr.
// - `.debug` is recorded in Logger only unless `AppLog.verbose` is true (then also stderr).
//
// DOES NOT
// - Write log files, use print(), or emit diagnostics on stdout.

/// Diagnostic logging: OSLog + stderr mirror for terminal users.
public struct AppLog {
    public static let subsystem = "ai.upil.appa"

    /// When true, `.debug` messages are also mirrored to stderr (future `--verbose`).
    public static var verbose = false

    public enum Category: String {
        case cli
        case daemon
        case capture
    }

    private let logger: Logger
    private let category: Category

    public init(category: Category) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        mirror(level: "info", message: message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        mirror(level: "warning", message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        mirror(level: "error", message: message)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        if Self.verbose {
            mirror(level: "debug", message: message)
        }
    }

    private func mirror(level: String, message: String) {
        let line = "[\(category.rawValue)] \(level): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}