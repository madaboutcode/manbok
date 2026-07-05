import Foundation
import ServiceManagement

// MARK: - CONTRACT: LoginItemManager
//
// GUARANTEES:
// - register() enables the app as a login item via SMAppService.mainApp.
// - unregister() removes it.
// - Both throw on macOS refusal (e.g. .requiresApproval).
//
// DOES NOT:
// - Persist the user's preference (see SettingsStore).
// - Show any UI or dialog (SMAppService may trigger a system notification on register —
//   that is macOS behavior, not ours).

/// Thin wrapper around SMAppService.mainApp for start-at-login.
public enum LoginItemManager {
    public static func register() throws {
        try SMAppService.mainApp.register()
    }

    public static func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// Current registration status, for UI display.
    public static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }
}
