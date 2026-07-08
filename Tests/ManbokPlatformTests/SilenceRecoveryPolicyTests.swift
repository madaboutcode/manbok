import XCTest
@testable import ManbokPlatform

final class SilenceRecoveryPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private func t(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    private let deviceA = CaptureTarget.device(101)
    private let deviceB = CaptureTarget.device(202)

    // MARK: - 1. Full ladder walk

    func test_fullLadderWalk_armedToHoldingViaReResolveThenRetry() {
        var policy = SilenceRecoveryPolicy(silenceThreshold: 10, maxSilentRestarts: 2)
        let silentSince = t(0)

        // armed, not yet expired.
        XCTAssertEqual(policy.evaluate(now: t(5), silentSince: silentSince, lastWorkerStartAt: t0),
                        .none)
        XCTAssertEqual(policy.state, .armed)

        // armed, expired -> reResolveAndRestart. State stays armed until noteRestart.
        XCTAssertEqual(policy.evaluate(now: t(10), silentSince: silentSince, lastWorkerStartAt: t0),
                        .reResolveAndRestart)
        XCTAssertEqual(policy.state, .armed)

        // Supervisor executes the restart onto target A.
        policy.noteRestart(target: deviceA)
        XCTAssertEqual(policy.state, .reResolving)

        // Fresh worker gets a full grace window from its own start time.
        let restart1At = t(10)
        XCTAssertEqual(policy.evaluate(now: t(15), silentSince: silentSince, lastWorkerStartAt: restart1At),
                        .none)

        // reResolving, expired again (still silent through the new worker's grace window)
        // -> reResolveAndRestart again.
        XCTAssertEqual(policy.evaluate(now: t(20), silentSince: silentSince, lastWorkerStartAt: restart1At),
                        .reResolveAndRestart)
        XCTAssertEqual(policy.state, .reResolving)

        // Supervisor re-resolves and restarts; resolution lands on the SAME target A.
        policy.noteRestart(target: deviceA)
        XCTAssertEqual(policy.state, .retrying)

        let restart2At = t(20)
        XCTAssertEqual(policy.evaluate(now: t(25), silentSince: silentSince, lastWorkerStartAt: restart2At),
                        .none)

        // retrying, expired again -> holdEntered exactly once; state -> holding immediately.
        XCTAssertEqual(policy.evaluate(now: t(30), silentSince: silentSince, lastWorkerStartAt: restart2At),
                        .holdEntered)
        XCTAssertEqual(policy.state, .holding)

        // Subsequent evaluates while still silent -> .none, no repeated holdEntered.
        XCTAssertEqual(policy.evaluate(now: t(40), silentSince: silentSince, lastWorkerStartAt: restart2At),
                        .none)
        XCTAssertEqual(policy.evaluate(now: t(100), silentSince: silentSince, lastWorkerStartAt: restart2At),
                        .none)
        XCTAssertEqual(policy.state, .holding)
    }

    // MARK: - 2. Signal at every state re-arms

    func test_signal_reArmsFromArmed() {
        var policy = SilenceRecoveryPolicy()
        XCTAssertEqual(policy.evaluate(now: t(0), silentSince: nil, lastWorkerStartAt: t0), .none)
        XCTAssertEqual(policy.state, .armed)
    }

    func test_signal_reArmsFromReResolving() {
        var policy = SilenceRecoveryPolicy(silenceThreshold: 10)
        _ = policy.evaluate(now: t(10), silentSince: t(0), lastWorkerStartAt: t0)
        policy.noteRestart(target: deviceA)
        XCTAssertEqual(policy.state, .reResolving)

        XCTAssertEqual(policy.evaluate(now: t(11), silentSince: nil, lastWorkerStartAt: t(10)), .none)
        XCTAssertEqual(policy.state, .armed)
    }

    func test_signal_reArmsFromRetrying() {
        var policy = SilenceRecoveryPolicy(silenceThreshold: 10)
        let silentSince = t(0)
        _ = policy.evaluate(now: t(10), silentSince: silentSince, lastWorkerStartAt: t0)
        policy.noteRestart(target: deviceA)
        _ = policy.evaluate(now: t(20), silentSince: silentSince, lastWorkerStartAt: t(10))
        policy.noteRestart(target: deviceA)
        XCTAssertEqual(policy.state, .retrying)

        XCTAssertEqual(policy.evaluate(now: t(21), silentSince: nil, lastWorkerStartAt: t(20)), .none)
        XCTAssertEqual(policy.state, .armed)
    }

    func test_signal_reArmsFromHolding() {
        var policy = enterHoldingPolicy()

        XCTAssertEqual(policy.evaluate(now: t(1000), silentSince: nil, lastWorkerStartAt: t(30)), .none)
        XCTAssertEqual(policy.state, .armed)
    }

    // MARK: - 3. Target change mid-ladder resets counts

    func test_targetChangeInReResolving_staysReResolvingAndReturnsReResolveAndRestartAgain() {
        var policy = SilenceRecoveryPolicy(silenceThreshold: 10)
        let silentSince = t(0)

        _ = policy.evaluate(now: t(10), silentSince: silentSince, lastWorkerStartAt: t0)
        policy.noteRestart(target: deviceA)
        XCTAssertEqual(policy.state, .reResolving)

        _ = policy.evaluate(now: t(20), silentSince: silentSince, lastWorkerStartAt: t(10))
        // Resolution lands on a DIFFERENT target this time (e.g. device swap).
        policy.noteRestart(target: deviceB)
        XCTAssertEqual(policy.state, .reResolving, "target change keeps the ladder at reResolving")

        // Next expired evaluate still asks for a fresh resolution, not restartInPlace.
        XCTAssertEqual(policy.evaluate(now: t(30), silentSince: silentSince, lastWorkerStartAt: t(20)),
                        .reResolveAndRestart)
        XCTAssertEqual(policy.state, .reResolving)
    }

    // MARK: - 4. Deferred execution repeats action

    func test_deferredExecution_repeatsActionWithoutAdvancing() {
        var policy = SilenceRecoveryPolicy(silenceThreshold: 10)
        let silentSince = t(0)

        XCTAssertEqual(policy.evaluate(now: t(10), silentSince: silentSince, lastWorkerStartAt: t0),
                        .reResolveAndRestart)
        XCTAssertEqual(policy.state, .armed)

        // Supervisor's restart budget defers execution: noteRestart is NOT called.
        XCTAssertEqual(policy.evaluate(now: t(11), silentSince: silentSince, lastWorkerStartAt: t0),
                        .reResolveAndRestart)
        XCTAssertEqual(policy.evaluate(now: t(50), silentSince: silentSince, lastWorkerStartAt: t0),
                        .reResolveAndRestart)
        XCTAssertEqual(policy.state, .armed)
    }

    // MARK: - 5. Start grace after restart

    func test_startGraceAfterRestart_silenceWindowResetsFromLastWorkerStartAt() {
        var policy = SilenceRecoveryPolicy(silenceThreshold: 10)
        let silentSince = t(0)

        // First restart happens at t(10) after the initial expiry.
        _ = policy.evaluate(now: t(10), silentSince: silentSince, lastWorkerStartAt: t0)
        policy.noteRestart(target: deviceA)

        // Even though silentSince is far in the past (>= threshold), the fresh worker's
        // start grants a full new grace window measured from lastWorkerStartAt.
        XCTAssertEqual(policy.evaluate(now: t(12), silentSince: silentSince, lastWorkerStartAt: t(10)),
                        .none, "fresh worker gets full grace, not judged by the old silentSince")

        // Grace window elapses relative to the NEW start time.
        XCTAssertEqual(policy.evaluate(now: t(20), silentSince: silentSince, lastWorkerStartAt: t(10)),
                        .reResolveAndRestart)
    }

    // MARK: - 6. Peak > 0 stream never triggers

    func test_continuousSignal_neverTriggersAndStaysArmed() {
        var policy = SilenceRecoveryPolicy(silenceThreshold: 10)

        for offset in stride(from: 0.0, through: 1000.0, by: 50.0) {
            XCTAssertEqual(policy.evaluate(now: t(offset), silentSince: nil, lastWorkerStartAt: t0),
                            .none)
            XCTAssertEqual(policy.state, .armed)
        }
    }

    // MARK: - 7. Holding exits on signal

    func test_holdingExitsOnSignal() {
        var policy = enterHoldingPolicy()

        let action = policy.evaluate(now: t(1000), silentSince: nil, lastWorkerStartAt: t(30))
        XCTAssertEqual(action, .none)
        XCTAssertEqual(policy.state, .armed)
    }

    // MARK: - 8. Holding exits on external change

    func test_holdingExitsOnExternalChange() {
        var policy = enterHoldingPolicy()

        policy.noteExternalChange()
        XCTAssertEqual(policy.state, .armed)

        // Ladder has fully re-armed: a silence window that hasn't yet reached the
        // threshold produces no action while armed.
        XCTAssertEqual(policy.evaluate(now: t(995), silentSince: t(990), lastWorkerStartAt: t(990)),
                        .none)
    }

    // MARK: - 9. Empty demand / no silence

    func test_noSilence_returnsNoneAndDoesNotChangeArmedState() {
        var policy = SilenceRecoveryPolicy()
        XCTAssertEqual(policy.state, .armed)

        XCTAssertEqual(policy.evaluate(now: t(0), silentSince: nil, lastWorkerStartAt: t0), .none)
        XCTAssertEqual(policy.state, .armed)
    }

    // MARK: - Helpers

    /// Drives a fresh policy through the full ladder into `.holding`, mirroring
    /// `test_fullLadderWalk_armedToHoldingViaReResolveThenRetry`.
    private func enterHoldingPolicy(silenceThreshold: TimeInterval = 10) -> SilenceRecoveryPolicy {
        var policy = SilenceRecoveryPolicy(silenceThreshold: silenceThreshold)
        let silentSince = t(0)

        _ = policy.evaluate(now: t(10), silentSince: silentSince, lastWorkerStartAt: t0)
        policy.noteRestart(target: deviceA)

        _ = policy.evaluate(now: t(20), silentSince: silentSince, lastWorkerStartAt: t(10))
        policy.noteRestart(target: deviceA)

        let action = policy.evaluate(now: t(30), silentSince: silentSince, lastWorkerStartAt: t(20))
        precondition(action == .holdEntered)
        precondition(policy.state == .holding)
        return policy
    }
}
