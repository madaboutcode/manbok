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
// - Silent-mic alarm: silenceAlarmEnabled (Bool, default false) and silenceAlarmSeconds (Int, default
//   30, one of SilenceAlarmConfig.durationChoices) persist under the same-named keys. Each change
//   logs one .notice line and calls silenceAlarmDidChange with the new config (not called by init).
//   init logs one .notice line with the loaded values. A stored seconds value that is not a
//   choice loads as the default.
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
    private static let silenceAlarmEnabledKey = "silenceAlarmEnabled"
    private static let silenceAlarmSecondsKey = "silenceAlarmSeconds"

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

    /// Set by the composition root to forward alarm changes to the silence-alarm monitor.
    public var silenceAlarmDidChange: ((SilenceAlarmConfig) -> Void)?

    public var silenceAlarm: SilenceAlarmConfig {
        SilenceAlarmConfig(enabled: silenceAlarmEnabled, seconds: silenceAlarmSeconds)
    }

    @Published public var silenceAlarmEnabled: Bool {
        didSet {
            guard silenceAlarmEnabled != oldValue else { return }
            defaults.set(silenceAlarmEnabled, forKey: Self.silenceAlarmEnabledKey)
            log.notice("silence alarm \(silenceAlarmEnabled ? "enabled" : "disabled")")
            silenceAlarmDidChange?(silenceAlarm)
        }
    }

    @Published public var silenceAlarmSeconds: Int {
        didSet {
            precondition(SilenceAlarmConfig.durationChoices.contains(silenceAlarmSeconds),
                         "silence alarm seconds not a choice: \(silenceAlarmSeconds)")
            guard silenceAlarmSeconds != oldValue else { return }
            defaults.set(silenceAlarmSeconds, forKey: Self.silenceAlarmSecondsKey)
            log.notice("silence alarm duration \(silenceAlarmSeconds) s")
            silenceAlarmDidChange?(silenceAlarm)
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
        self.silenceAlarmEnabled = defaults.bool(forKey: Self.silenceAlarmEnabledKey)
        let storedSeconds = defaults.integer(forKey: Self.silenceAlarmSecondsKey)
        // FALLBACK-OK: absent key reads 0 and a hand-edited value may be off-list; the contract above loads both as the default
        self.silenceAlarmSeconds = SilenceAlarmConfig.durationChoices.contains(storedSeconds)
            ? storedSeconds : SilenceAlarmConfig.defaultSeconds
        log.notice("settings loaded — silence alarm enabled=\(silenceAlarmEnabled) seconds=\(silenceAlarmSeconds)")
    }
}
