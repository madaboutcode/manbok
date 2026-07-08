import Foundation

// MARK: - CONTRACT: SilenceRecoveryPolicy
//
// GUARANTEES:
// - Pure policy: explicit now, no hidden clock, no AVFoundation.
// - Implements the silence-recovery ladder (spec R5/R6 STATES table):
//   armed → reResolving → retrying → holding.
// - evaluate() returns the action for this tick; state advances on noteRestart() or signal.
// - holdEntered is returned exactly once (the evaluate call itself transitions to .holding).
// - Ladder restarts share CaptureRestartPolicy's budget (enforced by supervisor, not here).
//
// EXPECTS:
// - Callers pass now explicitly (pure date arithmetic).
// - noteRestart() called for each EXECUTED silence-ladder restart.
// - noteExternalChange() called on demand/target changes from outside the ladder.
//
// DOES NOT: touch AVFoundation, timers, threads, workers, or registry.

public struct SilenceRecoveryPolicy {
    public let silenceThreshold: TimeInterval   // default 10
    public let maxSilentRestarts: Int           // default 2

    public enum State: Equatable, Sendable {
        case armed, reResolving, retrying, holding
    }

    public enum Action: Equatable, Sendable {
        case none
        case reResolveAndRestart   // ladder step 1
        case restartInPlace        // ladder step 2
        case holdEntered           // ladder exhausted — log .error ONCE, stop restarting
    }

    public private(set) var state: State = .armed

    private var previousRestartTarget: CaptureTarget?

    public init(silenceThreshold: TimeInterval = 10, maxSilentRestarts: Int = 2) {
        self.silenceThreshold = silenceThreshold
        self.maxSilentRestarts = maxSilentRestarts
    }

    /// Tick-time evaluation. silentSince: start of the current continuous digital-silence
    /// run (nil means the last chunk had signal, or no chunks yet). lastWorkerStartAt: the
    /// current worker attempt's start time — used to give a fresh worker a full grace window.
    public mutating func evaluate(now: Date, silentSince: Date?,
                                   lastWorkerStartAt: Date) -> Action {
        guard let silentSince else {
            state = .armed
            previousRestartTarget = nil
            return .none
        }

        switch state {
        case .holding:
            return .none

        case .armed:
            guard isExpired(now: now, silentSince: silentSince, lastWorkerStartAt: lastWorkerStartAt) else {
                return .none
            }
            return .reResolveAndRestart

        case .reResolving:
            guard isExpired(now: now, silentSince: silentSince, lastWorkerStartAt: lastWorkerStartAt) else {
                return .none
            }
            // Deferred execution: no noteRestart happened since we asked for the last
            // restart, so we keep asking for the same action without advancing state.
            return .reResolveAndRestart

        case .retrying:
            guard isExpired(now: now, silentSince: silentSince, lastWorkerStartAt: lastWorkerStartAt) else {
                return .none
            }
            // The single exception to "advance only on noteRestart": there is no restart
            // for a hold, so evaluate() itself performs the armed→holding transition here,
            // which is what makes holdEntered exactly-once.
            state = .holding
            return .holdEntered
        }
    }

    /// The supervisor reports each EXECUTED silence-ladder restart and its target.
    public mutating func noteRestart(target: CaptureTarget) {
        switch state {
        case .armed:
            state = .reResolving
            previousRestartTarget = target

        case .reResolving:
            if let previousRestartTarget, previousRestartTarget != target {
                // Fresh resolution landed on a different target — reset the ladder's
                // progress and stay in reResolving.
                self.previousRestartTarget = target
            } else {
                state = .retrying
                previousRestartTarget = target
            }

        case .retrying, .holding:
            // Restarts here are not expected by the ladder's own logic (retrying only
            // ever leads to holdEntered without a further restart, and holding issues no
            // restarts), but keep the target bookkeeping consistent defensively.
            previousRestartTarget = target
        }
    }

    /// Any target change or demand change from outside the ladder re-arms.
    public mutating func noteExternalChange() {
        state = .armed
        previousRestartTarget = nil
    }

    private func isExpired(now: Date, silentSince: Date, lastWorkerStartAt: Date) -> Bool {
        let windowStart = max(silentSince, lastWorkerStartAt)
        return now.timeIntervalSince(windowStart) >= silenceThreshold
    }
}
