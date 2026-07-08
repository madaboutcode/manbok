import Darwin
import Foundation

/// Socket lifecycle helper — removes stale Unix socket before app binds.
public enum DaemonProcess {
    public static func removeStaleSocket() {
        unlink(AppStatePaths.socketURL.path)
    }
}
