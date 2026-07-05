import Darwin
import Foundation

// MARK: - CONTRACT (MigrationService)
//
// GUARANTEES
// - Detects a legacy LaunchAgent plist at `~/Library/LaunchAgents/com.manbok.app.plist`;
//   if found, boots it out via `launchctl` and deletes the plist file.
// - Cleans stale `~/.manbok/run.sock` + `appa.pid` when the pid recorded in the pid file
//   is not alive, or cleans an orphaned socket when no pid file is present.
// - Safe to call multiple times (no-op when nothing stale is found).
//
// EXPECTS
// - Called once at app launch, before the daemon socket is bound.
//
// FAILURE BEHAVIOR
// - All filesystem/process errors are swallowed; migration is best-effort and never throws.
//
// DOES NOT
// - Start the app, bind sockets, or manage LoginItemManager.

public enum MigrationService {
    private static let legacyLaunchAgentLabel = "com.manbok.app"
    private static let log = AppLog(category: .app)

    /// Runs all migration checks against real system paths. Safe to call multiple times.
    public static func runIfNeeded() {
        log.info("migration: checking")
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLaunchAgentLabel).plist")

        removeLegacyLaunchAgent(plistURL: plistURL, fileManager: .default, bootout: bootoutLegacyLaunchAgent)
        cleanStaleDaemonState(
            socketURL: AppStatePaths.socketURL,
            pidURL: AppStatePaths.pidURL,
            fileManager: .default
        )
    }

    // MARK: - Testable internals

    static func removeLegacyLaunchAgent(
        plistURL: URL,
        fileManager: FileManager,
        bootout: () -> Void
    ) {
        guard fileManager.fileExists(atPath: plistURL.path) else { return }
        log.notice("migration: removing legacy LaunchAgent \(plistURL.lastPathComponent)")
        bootout()
        try? fileManager.removeItem(at: plistURL)
    }

    static func cleanStaleDaemonState(socketURL: URL, pidURL: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: pidURL.path),
              let pidString = try? String(contentsOf: pidURL, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(pidString)
        else {
            if fileManager.fileExists(atPath: socketURL.path) {
                log.notice("migration: removing orphaned socket")
                try? fileManager.removeItem(at: socketURL)
            }
            return
        }

        guard !processIsAlive(pid) else { return }

        log.notice("migration: cleaning stale daemon state (pid \(pid) is dead)")
        try? fileManager.removeItem(at: socketURL)
        try? fileManager.removeItem(at: pidURL)
    }

    private static func bootoutLegacyLaunchAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(legacyLaunchAgentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else {
            return errno == EPERM
        }
        return true
    }
}
