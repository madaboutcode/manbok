import Darwin
import Foundation

// MARK: - CONTRACT (SingleInstance)
//
// GUARANTEES
// - `InstanceLock.acquire` takes an exclusive, non-blocking `flock` on the lock file. It returns the lock
//   when this process now owns it, `nil` when another open file description (any process) holds it.
// - The lock lives as long as the `InstanceLock` object; the OS releases it when the process dies.
// - The lock fd is close-on-exec, so spawned children never inherit ownership.
// - `SingleInstance.claim` is the launch decision: `.proceed(lock)` only while holding the lock.
//   When the lock is held elsewhere it PINGs that instance's socket and returns `.otherRunning` (it
//   answered) or `.otherUnresponsive` (it did not), after writing a persisted log line.
// - `claim` never unlinks or modifies anything other than creating the lock file and its directory.
//
// EXPECTS
// - Called first at launch, before migration, checkpoint restore/clear, or any socket work.
//
// FAILURE BEHAVIOR
// - open/flock failures other than "already locked" throw `InstanceLockError`.
//
// DOES NOT
// - Terminate the process (the caller exits on `.otherRunning` / `.otherUnresponsive`).
// - Unblock, kill, or take over an unresponsive holder.

public enum InstanceLockError: Error, Equatable {
    case syscall(String)
}

public final class InstanceLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    public static func acquire(at lockURL: URL) throws -> InstanceLock? {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw InstanceLockError.syscall("open errno=\(errno)") }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return InstanceLock(fd: fd) }
        let err = errno
        close(fd)
        guard err == EWOULDBLOCK else { throw InstanceLockError.syscall("flock errno=\(err)") }
        return nil
    }
}

public enum LaunchClaim {
    case proceed(InstanceLock)
    case otherRunning
    case otherUnresponsive
}

public enum SingleInstance {
    private static let log = AppLog(category: .app)
    private static let pingTimeout: TimeInterval = 2

    public static func claim(
        lockURL: URL = AppStatePaths.lockURL,
        socketURL: URL = AppStatePaths.socketURL
    ) throws -> LaunchClaim {
        if let lock = try InstanceLock.acquire(at: lockURL) {
            return .proceed(lock)
        }
        if let response = try? UnixSocketClient.send(command: .ping, socketURL: socketURL, timeout: pingTimeout),
           case .pong = response {
            log.notice("single-instance: another instance is running and answered PING; exiting")
            return .otherRunning
        }
        log.error("single-instance: lock is held but the holder did not answer PING within \(Int(pingTimeout)) s; it may be hung. Exiting without touching its state")
        return .otherUnresponsive
    }
}
