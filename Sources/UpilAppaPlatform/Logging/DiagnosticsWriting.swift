import Foundation
import os

// MARK: - CONTRACT (DiagnosticsWriting)
//
// GUARANTEES
// - All implementations record to os.Logger subsystem ai.upil.appa.
// - Stderr mirror is opt-in per sink (CLI only in production).
//
// DOES NOT
// - Paint the foreground meter or touch stdout.

public protocol DiagnosticsWriting: Sendable {
    func info(category: AppLog.Category, _ message: String)
    func warning(category: AppLog.Category, _ message: String)
    func error(category: AppLog.Category, _ message: String)
    func debug(category: AppLog.Category, _ message: String)
}

/// Console.app only — detached and foreground daemon.
public struct OSLogOnlyDiagnostics: DiagnosticsWriting {
    public init() {}

    public func info(category: AppLog.Category, _ message: String) {
        logger(category).info("\(message, privacy: .public)")
    }

    public func warning(category: AppLog.Category, _ message: String) {
        logger(category).warning("\(message, privacy: .public)")
    }

    public func error(category: AppLog.Category, _ message: String) {
        logger(category).error("\(message, privacy: .public)")
    }

    public func debug(category: AppLog.Category, _ message: String) {
        logger(category).debug("\(message, privacy: .public)")
    }

    private func logger(_ category: AppLog.Category) -> Logger {
        Logger(subsystem: AppLog.subsystem, category: category.rawValue)
    }
}

/// Console + stderr — interactive CLI subcommands (start/stop/status/dump).
public struct OSLogAndStderrDiagnostics: DiagnosticsWriting {
    public init() {}

    public func info(category: AppLog.Category, _ message: String) {
        logger(category).info("\(message, privacy: .public)")
        mirror(category: category, level: "info", message: message)
    }

    public func warning(category: AppLog.Category, _ message: String) {
        logger(category).warning("\(message, privacy: .public)")
        mirror(category: category, level: "warning", message: message)
    }

    public func error(category: AppLog.Category, _ message: String) {
        logger(category).error("\(message, privacy: .public)")
        mirror(category: category, level: "error", message: message)
    }

    public func debug(category: AppLog.Category, _ message: String) {
        logger(category).debug("\(message, privacy: .public)")
        if AppLog.verbose {
            mirror(category: category, level: "debug", message: message)
        }
    }

    private func logger(_ category: AppLog.Category) -> Logger {
        Logger(subsystem: AppLog.subsystem, category: category.rawValue)
    }

    private func mirror(category: AppLog.Category, level: String, message: String) {
        let line = "[\(category.rawValue)] \(level): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}