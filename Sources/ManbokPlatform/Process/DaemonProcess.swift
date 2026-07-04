import Darwin
import Foundation

// MARK: - CONTRACT (DaemonProcess)
//
// GUARANTEES
// - `isRunning()` reads `AppStatePaths.pidURL` and verifies the process is alive.
// - `startDaemon(executablePath:)` spawns a detached child that execs `<path> daemon`.
// - `removeStaleSocket()` unlinks `AppStatePaths.socketURL` when reclaiming or before start.
// - Dead pid in the pid file → reclaim pid file and stale socket.
//
// EXPECTS
// - Daemon entry writes the pid file after exec (see `DaemonMain`).
//
// FAILURE BEHAVIOR
// - Spawn failures throw `DaemonProcessError`.
// - Stale state is reclaimed automatically on `isRunning()` when pid is not alive.
//
// DOES NOT
// - Bind sockets, capture audio, or parse CLI subcommands (see DaemonMain / CommandRouter).

public enum DaemonProcessError: Error, Equatable, Sendable {
    case spawnFailed(errno: Int32)
}

/// Spawn/detach helper and pid/socket lifecycle for the listener daemon.
public enum DaemonProcess {
    public static func isRunning() -> Bool {
        guard let pid = readPID() else {
            return false
        }
        if processIsAlive(pid) {
            return true
        }
        reclaimStaleState()
        return false
    }

    /// Spawns a detached child: `executablePath daemon` plus optional extra args (e.g. `always-on`).
    public static func startDaemon(executablePath: String, daemonArguments: [String] = []) throws {
        removeStaleSocket()

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            throw DaemonProcessError.spawnFailed(errno: errno)
        }
        defer { posix_spawnattr_destroy(&attr) }

        let flags = Int16(POSIX_SPAWN_SETSID)
        guard posix_spawnattr_setflags(&attr, flags) == 0 else {
            throw DaemonProcessError.spawnFailed(errno: errno)
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw DaemonProcessError.spawnFailed(errno: errno)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let devNull = open("/dev/null", O_RDWR)
        guard devNull >= 0 else {
            throw DaemonProcessError.spawnFailed(errno: errno)
        }
        defer { close(devNull) }

        for fd: Int32 in [0, 1, 2] {
            guard posix_spawn_file_actions_adddup2(&fileActions, devNull, fd) == 0 else {
                throw DaemonProcessError.spawnFailed(errno: errno)
            }
        }

        let argv: [String] = [executablePath, "daemon"] + daemonArguments
        let argvPointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer {
            for pointer in argvPointers where pointer != nil {
                free(pointer)
            }
        }

        var pid: pid_t = 0
        let spawnResult = argvPointers.withUnsafeBufferPointer { buffer in
            executablePath.withCString { path in
                posix_spawn(&pid, path, &fileActions, &attr, buffer.baseAddress, nil)
            }
        }

        guard spawnResult == 0 else {
            throw DaemonProcessError.spawnFailed(errno: spawnResult)
        }
    }

    /// Removes the Unix socket path if present (safe when daemon is not listening).
    public static func removeStaleSocket() {
        unlink(AppStatePaths.socketURL.path)
    }

    public static func writeCurrentPID() throws {
        try AppStatePaths.ensureDirectory()
        let line = "\(getpid())\n"
        try line.write(to: AppStatePaths.pidURL, atomically: true, encoding: .utf8)
    }

    private static func readPID() -> pid_t? {
        guard let text = try? String(contentsOf: AppStatePaths.pidURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(trimmed) else { return nil }
        return pid_t(value)
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else {
            return errno == EPERM
        }
        return true
    }

    /// Removes pid file and socket (safe when daemon is exiting or stale).
    public static func reclaimStaleState() {
        try? FileManager.default.removeItem(at: AppStatePaths.pidURL)
        removeStaleSocket()
    }
}