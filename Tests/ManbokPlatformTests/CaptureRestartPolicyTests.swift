import XCTest
@testable import ManbokPlatform

/// Contract tests for CaptureRestartPolicy (see its CONTRACT block). The scenarios mirror
/// the spike evidence in tasks/decisions-20260706-device-change-robustness.md: the
/// incident (one healthy restart), the DOA race (quick unhealthy restart, then healthy),
/// and the flap loop (backoff must grow to the cap — never a tight restart loop).
final class CaptureRestartPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makePolicy() -> CaptureRestartPolicy {
        CaptureRestartPolicy(watchdogThreshold: 4, baseDelay: 1, maxDelay: 30)
    }

    // MARK: - Watchdog (isStalled)

    func testFreshEngineIsNotStalledBeforeThreshold() {
        let policy = makePolicy()
        XCTAssertFalse(policy.isStalled(lastDataAt: nil, captureStartedAt: t0, now: t0.addingTimeInterval(3.9)),
                       "engine start counts as evidence — no condemnation before the threshold")
    }

    func testEngineWithNoBytesEverIsStalledAfterThreshold() {
        let policy = makePolicy()
        XCTAssertTrue(policy.isStalled(lastDataAt: nil, captureStartedAt: t0, now: t0.addingTimeInterval(4.0)),
                      "the DOA race: started, never delivered a byte")
    }

    func testFlowingCaptureIsNotStalled() {
        let policy = makePolicy()
        let now = t0.addingTimeInterval(60)
        XCTAssertFalse(policy.isStalled(lastDataAt: now.addingTimeInterval(-1), captureStartedAt: t0, now: now))
    }

    func testCaptureStalledAfterBytesStop() {
        let policy = makePolicy()
        let lastData = t0.addingTimeInterval(37) // the incident: healthy for 37s, then silence
        XCTAssertTrue(policy.isStalled(lastDataAt: lastData, captureStartedAt: t0, now: lastData.addingTimeInterval(4)))
    }

    // MARK: - Rate limiting (mayRestart)

    func testFirstStartIsAlwaysAllowed() {
        let policy = makePolicy()
        XCTAssertTrue(policy.mayRestart(now: t0))
    }

    func testSignalStormWithinDelayIsSuppressed() {
        var policy = makePolicy()
        policy.recordRestart(now: t0, wasFlowing: false)
        XCTAssertFalse(policy.mayRestart(now: t0.addingTimeInterval(0.5)),
                       "config-change storms 100-800ms after start must not trigger immediate re-restart")
        XCTAssertTrue(policy.mayRestart(now: t0.addingTimeInterval(1.0)))
    }

    // MARK: - Backoff (recordRestart / currentDelay)

    func testRestartOfFlowingEngineDoesNotGrowBackoff() {
        var policy = makePolicy()
        policy.recordRestart(now: t0, wasFlowing: false)                         // initial start
        policy.recordRestart(now: t0.addingTimeInterval(1800), wasFlowing: true) // BT switch mid-meeting
        XCTAssertEqual(policy.consecutiveUnhealthyRestarts, 0)
        XCTAssertEqual(policy.currentDelay, 1)
    }

    func testFlapGrowsBackoffMonotonicallyToCap() {
        var policy = makePolicy()
        var now = t0
        policy.recordRestart(now: now, wasFlowing: false) // initial start (neutral)
        var observedDelays: [TimeInterval] = []
        for _ in 0..<7 { // engine dies instantly every time; watchdog keeps reviving it
            now = now.addingTimeInterval(policy.currentDelay + 4)
            policy.recordRestart(now: now, wasFlowing: false)
            observedDelays.append(policy.currentDelay)
        }
        XCTAssertEqual(observedDelays, [2, 4, 8, 16, 30, 30, 30],
                       "flap converges to one attempt per maxDelay — no mic-indicator strobe."
                           + " Elapsed time must NOT reset health: backoff itself stretches"
                           + " the gap between attempts, so a time-based reset would re-accelerate the flap")
    }

    func testFlowingRestartResetsBackoff() {
        var policy = makePolicy()
        policy.recordRestart(now: t0, wasFlowing: false)
        policy.recordRestart(now: t0.addingTimeInterval(2), wasFlowing: false) // dead engine revived
        policy.recordRestart(now: t0.addingTimeInterval(4), wasFlowing: false) // dead again
        XCTAssertEqual(policy.consecutiveUnhealthyRestarts, 2)
        policy.recordRestart(now: t0.addingTimeInterval(60), wasFlowing: true) // engine was delivering
        XCTAssertEqual(policy.consecutiveUnhealthyRestarts, 0)
        XCTAssertEqual(policy.currentDelay, 1)
    }

    func testResetRestoresPristineState() {
        var policy = makePolicy()
        policy.recordRestart(now: t0, wasFlowing: false)
        policy.recordRestart(now: t0.addingTimeInterval(1), wasFlowing: false)
        policy.reset()
        XCTAssertEqual(policy.consecutiveUnhealthyRestarts, 0)
        XCTAssertNil(policy.lastRestartAt)
        XCTAssertTrue(policy.mayRestart(now: t0.addingTimeInterval(1.1)))
    }
}
