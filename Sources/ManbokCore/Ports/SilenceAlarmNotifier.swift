import Foundation

/// What the user is told when the silent-mic alarm raises.
public struct SilenceAlarmNotice: Equatable, Sendable {
    public let apps: [String]
    public let device: String
    public let silentSeconds: Int

    public init(apps: [String], device: String, silentSeconds: Int) {
        self.apps = apps
        self.device = device
        self.silentSeconds = silentSeconds
    }
}

/// Delivers the silent-mic alarm outside the app window (a system notification).
public protocol SilenceAlarmNotifying: AnyObject, Sendable {
    /// Called when the user switches the alarm on; may show a system permission prompt.
    /// `completion` receives whether notifications are allowed; it may run on any thread, and
    /// possibly before this method returns. A notice posted before it runs may be lost.
    func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void)
    func post(_ notice: SilenceAlarmNotice)
    /// Removes a delivered notice once the alarm cleared.
    func withdraw()
}
