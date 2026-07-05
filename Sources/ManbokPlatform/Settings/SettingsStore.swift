import Combine
import Foundation
import ManbokCore

// MARK: - CONTRACT: SettingsStore
//
// GUARANTEES:
// - Persists bufferPreset + startAtLogin to the given UserDefaults suite (default:
//   "ai.manbok.app"), keyed by "bufferPreset" / "startAtLogin".
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
    }
}
