import CoreAudio
import Foundation

// MARK: - CONTRACT (AUHALEnvironmentSignals)
//
// GUARANTEES
// - Implements EnvironmentSignaling for the AUHAL backend.
// - defaultInputChanged: sourced from InputDeviceObserver.addDefaultInputChangeHandler
//   (backend-neutral).
// - captureDisturbed: HAL property listeners on the currently observed device —
//   kAudioDevicePropertyDeviceIsAlive (device death), kAudioDevicePropertyStreamConfiguration
//   and kAudioDevicePropertyNominalSampleRate (format change).
// - Forwards each raw signal to handler as-is — no filtering, no debounce, no rate limiting.
// - activate()/deactivate()/observe(device:) are idempotent.
// - No handler calls after deactivate() returns.
// - observe(device:) re-targets the per-device listeners to the new device, tearing down
//   listeners on the previous device first.
//
// EXPECTS
// - handler is thread-safe (supervisor mailboxes under a lock).
// - observe(device:) called by the supervisor after each successful (re)start.
//
// FAILURE BEHAVIOR (gate F6)
// - Listener registration failures are logged .warning, naming the source, and otherwise
//   ignored — a dead signal source is accepted degradation; the supervisor's tick
//   watchdogs are the detection backstop regardless of signals.
//
// DOES NOT
// - Decide, restart, or touch workers/registry.

public final class AUHALEnvironmentSignals: EnvironmentSignaling {
    private let log = AppLog(category: .capture)
    private let listenerQueue = DispatchQueue(label: "ai.manbok.app.auhalenvironmentsignals")

    public var handler: ((EnvironmentSignal) -> Void)?

    private let stateLock = NSLock()
    private var isActive = false
    private var removeDefaultInputHandler: (() -> Void)?
    private var observedDevice: AudioDeviceID?
    private var deviceListeners: [InstalledListener] = []

    private struct InstalledListener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private static let deviceDisturbanceProperties:
        [(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, reason: String)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, "device is no longer alive"),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput, "stream configuration changed"),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, "nominal sample rate changed"),
        ]

    public init() {}

    public func activate() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isActive else { return }
        isActive = true
        removeDefaultInputHandler = InputDeviceObserver.addDefaultInputChangeHandler { [weak self] in
            self?.forward(.defaultInputChanged)
        }
    }

    public func deactivate() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive else { return }
        isActive = false
        removeDefaultInputHandler?()
        removeDefaultInputHandler = nil
        removeDeviceListenersLocked()
        observedDevice = nil
    }

    public func observe(device: AudioDeviceID?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        removeDeviceListenersLocked()
        observedDevice = device
        guard isActive, let device else { return }
        installDeviceListenersLocked(on: device)
    }

    private func forward(_ signal: EnvironmentSignal) {
        stateLock.lock()
        let active = isActive
        let currentHandler = handler
        stateLock.unlock()
        guard active else { return }
        currentHandler?(signal)
    }

    // MARK: - Device-scoped listeners (caller holds stateLock)

    private func installDeviceListenersLocked(on device: AudioDeviceID) {
        for (selector, scope, reason) in Self.deviceDisturbanceProperties {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.forward(.captureDisturbed("device \(device) — \(reason)"))
            }
            let status = AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block)
            if status == noErr {
                deviceListeners.append(InstalledListener(address: address, block: block))
            } else {
                log.warning("failed to register listener (selector=\(selector)) on device \(device): OSStatus \(status)")
            }
        }
    }

    private func removeDeviceListenersLocked() {
        guard let device = observedDevice else {
            deviceListeners.removeAll()
            return
        }
        for var listener in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(device, &listener.address, listenerQueue, listener.block)
        }
        deviceListeners.removeAll()
    }
}
