import Foundation
import ManbokCore
import UserNotifications

/// Shows the silent-mic alarm as a macOS notification. Needs the app bundle: the notification
/// center is not available to a bare executable, so `UNUserNotificationCenter.current()` is only
/// touched when a method runs, never at construction.
public final class UserNotificationSilenceAlarmNotifier: NSObject, SilenceAlarmNotifying, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let identifier = "ai.manbok.silent-mic-alarm"
    private let log = AppLog(category: .capture)

    public override init() { super.init() }

    public func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            if let error {
                log.error("notification authorization failed: \(error.localizedDescription)")
            } else {
                log.notice("notification authorization \(granted ? "granted" : "denied")")
            }
        }
    }

    public func post(_ notice: SilenceAlarmNotice) {
        let content = UNMutableNotificationContent()
        content.title = "No sound from your mic"
        let who = notice.apps.isEmpty ? "An app is" : notice.apps.joined(separator: ", ") + " is"
        content.body = "\(who) using \(notice.device), but it has delivered silence for \(notice.silentSeconds) s."
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.add(request) { [log] error in
            if let error { log.error("notification post failed: \(error.localizedDescription)") }
        }
    }

    public func withdraw() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
