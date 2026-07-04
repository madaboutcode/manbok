import Foundation

// MARK: - CONTRACT (AppStatePaths)
//
// GUARANTEES
// - State directory is `~/.manbok/`.
// - `socketURL` → `run.sock`, `pidURL` → `appa.pid`.
// - `ensureDirectory()` creates the state directory when missing.
//
// DOES NOT
// - Bind sockets, write pid files, or detect stale processes (see DaemonProcess).

/// Persistent paths for daemon IPC and process identity.
public enum AppStatePaths {
    private static let stateDirName = ".manbok"
    private static let socketFileName = "run.sock"
    private static let pidFileName = "appa.pid"

    public static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(stateDirName, isDirectory: true)
    }

    public static var socketURL: URL {
        stateDirectory.appendingPathComponent(socketFileName)
    }

    public static var pidURL: URL {
        stateDirectory.appendingPathComponent(pidFileName)
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
    }
}