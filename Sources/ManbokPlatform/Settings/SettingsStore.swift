import Combine
import Foundation
import ManbokCore

// MARK: - CONTRACT: SettingsStore
//
// GUARANTEES:
// - Persists bufferPreset + startAtLogin + excludedApps to the given UserDefaults suite (default:
//   "ai.manbok.app"), keyed by "bufferPreset" / "startAtLogin" / "excludedApps".
// - excludedApps holds app GROUP keys (appGroup(_:)), stored as a sorted string array. Each change
//   logs one .notice line per added or removed group and then calls excludedAppsDidChange (not
//   called by init).
// - Publishes @Published bufferPreset and @Published startAtLogin for SwiftUI binding.
// - An unreadable or unrecognized stored preset value falls back to BufferPolicy.Preset.default
//   (.min10) rather than crashing.
//
// DOES NOT:
// - Resize the ring buffer when bufferPreset changes (see SessionRegistry.resize).
// - Register or unregister login items when startAtLogin changes (see ManbokApp, Phase 3).

/// Thin UserDefaults-backed store for user-configurable settings.
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private let log = AppLog(category: .settings)

    private static let bufferPresetKey = "bufferPreset"
    private static let startAtLoginKey = "startAtLogin"
    private static let excludedAppsKey = "excludedApps"

    /// Set by the composition root to forward changes to the lifecycle executor.
    public var excludedAppsDidChange: ((Set<String>) -> Void)?

    @Published public var excludedApps: Set<String> {
        didSet {
            guard excludedApps != oldValue else { return }
            defaults.set(excludedApps.sorted(), forKey: Self.excludedAppsKey)
            for group in excludedApps.subtracting(oldValue).sorted() { log.notice("exclusion added — \(group)") }
            for group in oldValue.subtracting(excludedApps).sorted() { log.notice("exclusion removed — \(group)") }
            excludedAppsDidChange?(excludedApps)
        }
    }

    @Published public var bufferPreset: BufferPolicy.Preset {
        didSet {
            defaults.set(bufferPreset.rawValue, forKey: Self.bufferPresetKey)
            log.info("persisted bufferPreset=\(bufferPreset.rawValue)")
        }
    }

    @Published public var startAtLogin: Bool {
        didSet {
            defaults.set(startAtLogin, forKey: Self.startAtLoginKey)
            log.info("persisted startAtLogin=\(startAtLogin)")
        }
    }

    public init(defaults: UserDefaults = UserDefaults(suiteName: "ai.manbok.app") ?? .standard) {
        self.defaults = defaults

        let storedPreset = defaults.string(forKey: Self.bufferPresetKey)
            .flatMap(BufferPolicy.Preset.init(rawValue:))
        self.bufferPreset = storedPreset ?? .default
        self.startAtLogin = defaults.bool(forKey: Self.startAtLoginKey)
        self.excludedApps = Set(defaults.stringArray(forKey: Self.excludedAppsKey) ?? [])
    }
}
