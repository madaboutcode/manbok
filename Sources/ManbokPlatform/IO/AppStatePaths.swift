import Foundation

// MARK: - CONTRACT (AppStatePaths)
//
// GUARANTEES
// - State directory is `~/.manbok/`.
// - `socketURL` → `run.sock`, `pidURL` → `appa.pid`, `lockURL` → `instance.lock` (single-instance flock, see SingleInstance).
// - `ensureDirectory()` creates the state directory when missing.
//
// DOES NOT
// - Bind sockets, write pid files, or detect stale processes (see DaemonProcess).

/// Persistent paths for daemon IPC and process identity.
public enum AppStatePaths {
    private static let stateDirName = ".manbok"
    private static let socketFileName = "run.sock"
    private static let pidFileName = "appa.pid"
    private static let lockFileName = "instance.lock"

    /// Test seam: when set, all state paths resolve under this directory instead of `~/.manbok/`.
    nonisolated(unsafe) static var stateDirectoryOverride: URL?

    public static var stateDirectory: URL {
        if let override = stateDirectoryOverride { return override }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(stateDirName, isDirectory: true)
    }

    public static var socketURL: URL {
        stateDirectory.appendingPathComponent(socketFileName)
    }

    public static var pidURL: URL {
        stateDirectory.appendingPathComponent(pidFileName)
    }

    public static var lockURL: URL {
        stateDirectory.appendingPathComponent(lockFileName)
    }

    /// Legacy pre-generation checkpoint location (state root). Read once by `StatePersistenceService.restore`.
    public static var ringManifestURL: URL {
        stateDirectory.appendingPathComponent("ring.json")
    }

    public static var ringDataURL: URL {
        stateDirectory.appendingPathComponent("ring.pcm")
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
    }
}