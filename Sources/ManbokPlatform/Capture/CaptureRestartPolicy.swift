import Foundation

// MARK: - CONTRACT: CaptureRestartPolicy
//
// GUARANTEES:
// - isStalled: true iff capture is nominally running but no audio bytes have arrived for
//   watchdogThreshold, counting engine start itself as evidence (a fresh engine gets
//   watchdogThreshold to produce its first byte before it counts as stalled).
// - mayRestart: rate-limits restarts — false within currentDelay of the previous restart.
// - currentDelay grows exponentially (baseDelay · 2^unhealthy, capped at maxDelay) while
//   restarts happen WITHOUT audio flowing beforehand (wasFlowing=false), and resets to
//   baseDelay on any restart of a working engine. Health is byte-flow, deliberately NOT
//   elapsed time: backoff inflates the time between attempts, so a time-based health
//   proxy resets itself and the flap accelerates again (caught by unit test). A device
//   that can never hold capture converges to one attempt per maxDelay — no flap loop,
//   no strobing mic indicator.
//
// EXPECTS:
// - Callers pass `now` explicitly (pure date arithmetic; no hidden clock — unit-testable).
// - recordRestart is called for every capture start ATTEMPT, initial or restart,
//   successful or thrown; wasFlowing = bytes arrived within watchdogThreshold of the
//   attempt. The first attempt (no prior restart) is neutral regardless of wasFlowing.
//
// DOES NOT:
// - Touch AVFoundation, timers, or threads. Decision logic only.

/// Decides when the capture engine may be (re)started after device-change signals,
/// byte-flow stalls, or start failures. Spike-validated inputs (2026-06-06,
/// tasks/decisions-20260706-device-change-robustness.md): config-change signal storms
/// must be coalesced, but a debounce alone can swallow the terminal stop event — the
/// byte-flow watchdog is the backstop, and backoff is what prevents a visible flap loop.
public struct CaptureRestartPolicy {
    /// Capture counts as stalled after this long without bytes (2 poll ticks at the 2s cadence).
    public let watchdogThreshold: TimeInterval
    /// Minimum spacing between restarts while healthy; also the backoff base.
    public let baseDelay: TimeInterval
    /// Backoff ceiling for a persistently failing device.
    public let maxDelay: TimeInterval

    public private(set) var consecutiveUnhealthyRestarts = 0
    public private(set) var lastRestartAt: Date?

    public init(
        watchdogThreshold: TimeInterval = 4.0,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0
    ) {
        self.watchdogThreshold = watchdogThreshold
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public var currentDelay: TimeInterval {
        min(baseDelay * pow(2, Double(consecutiveUnhealthyRestarts)), maxDelay)
    }

    /// True iff no byte-flow evidence for watchdogThreshold. `captureStartedAt` counts as
    /// evidence so a freshly started engine is not immediately condemned.
    public func isStalled(lastDataAt: Date?, captureStartedAt: Date, now: Date) -> Bool {
        let lastEvidence = max(lastDataAt ?? .distantPast, captureStartedAt)
        return now.timeIntervalSince(lastEvidence) >= watchdogThreshold
    }

    /// True when enough time has passed since the previous restart (backoff-aware).
    public func mayRestart(now: Date) -> Bool {
        guard let last = lastRestartAt else { return true }
        return now.timeIntervalSince(last) >= currentDelay
    }

    /// Record a capture start attempt. wasFlowing: bytes were arriving right up to this
    /// attempt (a live engine being switched) — restarting a dead one grows the backoff.
    public mutating func recordRestart(now: Date, wasFlowing: Bool) {
        if lastRestartAt != nil, !wasFlowing {
            consecutiveUnhealthyRestarts += 1
        } else {
            consecutiveUnhealthyRestarts = 0
        }
        lastRestartAt = now
    }

    /// Back to pristine state (capture stopped cleanly; next session starts fresh).
    public mutating func reset() {
        consecutiveUnhealthyRestarts = 0
        lastRestartAt = nil
    }
}
