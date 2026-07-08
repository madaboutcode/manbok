import CoreAudio
import Foundation

// MARK: - CONTRACT: EnvironmentSignals
//
// PURPOSE: Protocol for environment signal sources. Normalizes raw OS signals into
// EnvironmentSignal and forwards to handler. Backend-specific impl lands with the
// worker (follow-up after P1–P5).
//
// GUARANTEES:
// - No filtering, no debounce, no rate limiting (supervisor's budget owns suppression).
// - defaultInputChanged: sourced from InputDeviceObserver (backend-neutral).
// - captureDisturbed: per backend (device-alive, stream-format, runtime-error).
// - activate/deactivate/observe idempotent; no handler calls after deactivate() returns.
//
// EXPECTS:
// - handler is thread-safe (supervisor mailboxes under a lock).
// - observe(device:) called after each successful (re)start.
//
// FAILURE:
// - Registration failure: logged .warning, accepted degradation. Signals only accelerate
//   recovery; tick watchdogs are the detection backstop.
//
// DOES NOT: decide, restart, or touch workers/registry.

public enum EnvironmentSignal: Equatable, Sendable {
    case defaultInputChanged            // system default input moved (backend-neutral)
    case captureDisturbed(String)       // backend-reported: device died, format lost,
}                                       // session runtime error — reason for the log

public protocol EnvironmentSignaling: AnyObject {
    var handler: ((EnvironmentSignal) -> Void)? { get set }
    func activate()
    func deactivate()
    /// Current bound device (nil = none); per-attempt listeners re-target here (D6).
    func observe(device: AudioDeviceID?)
}
