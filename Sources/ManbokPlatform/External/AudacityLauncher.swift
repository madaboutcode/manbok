import Foundation

// MARK: - CONTRACT (AudacityLauncher)
//
// GUARANTEES
// - Opens a WAV file in Audacity via `/usr/bin/open -a Audacity <path>`.
// - Returns false when the open command fails; does not delete the WAV.
//
// DOES NOT
// - Block on user saving in Audacity or run from the daemon process.

/// Opens a dump WAV in Audacity (CLI-only).
public enum AudacityLauncher {
    /// Launches Audacity with the given filesystem path. Returns whether `open` exited successfully.
    public static func open(path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Audacity", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}