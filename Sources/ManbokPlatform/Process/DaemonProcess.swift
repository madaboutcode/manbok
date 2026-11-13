import Darwin
import Foundation

/// Socket lifecycle helper — removes stale Unix socket before app binds.
public enum DaemonProcess {
    /// Requires proof that this process owns the instance lock: without it the socket may belong to a live instance.
    public static func removeStaleSocket(holding _: InstanceLock) {
        unlink(AppStatePaths.socketURL.path)
    }
}
