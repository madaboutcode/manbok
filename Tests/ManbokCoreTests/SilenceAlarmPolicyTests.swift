import XCTest
@testable import ManbokCore

final class SilenceAlarmPolicyTests: XCTestCase {
    private func policy(enabled: Bool = true, seconds: Int = 30, open: Bool = true) -> SilenceAlarmPolicy {
        var p = SilenceAlarmPolicy(config: SilenceAlarmConfig(enabled: enabled, seconds: seconds))
        if open { _ = p.step(.sessionsOpen(true), now: 0) }
        return p
    }

    func test_silenceShorterThanDuration_doesNotRaise() {
        var p = policy()
        XCTAssertEqual(p.step(.tick, now: 29.9), .none)
        XCTAssertFalse(p.isRaised)
    }

    func test_silenceReachingDuration_raisesOnceAndNotAgain() {
        var p = policy()
        XCTAssertEqual(p.step(.tick, now: 30), .raise(silentFor: 30))
        XCTAssertEqual(p.step(.tick, now: 32), .none)
        XCTAssertEqual(p.step(.tick, now: 300), .none)
        XCTAssertTrue(p.isRaised)
    }

    func test_noChunksAtAll_countsAsSilence() {
        // Only ticks arrive (capture stalled or restarting): the alarm still raises.
        var p = policy()
        for t in stride(from: 2.0, to: 30.0, by: 2.0) { XCTAssertEqual(p.step(.tick, now: t), .none) }
        XCTAssertEqual(p.step(.tick, now: 30), .raise(silentFor: 30))
    }

    func test_audibleChunk_clearsRaisedAlarm() {
        var p = policy()
        _ = p.step(.tick, now: 31)
        XCTAssertEqual(p.step(.audibleChunk, now: 40), .clear(.audible))
        XCTAssertFalse(p.isRaised)
    }

    func test_audibleChunk_restartsClock() {
        var p = policy()
        _ = p.step(.audibleChunk, now: 25)
        XCTAssertEqual(p.step(.tick, now: 54), .none)
        XCTAssertEqual(p.step(.tick, now: 55), .raise(silentFor: 30))
    }

    func test_newStretchAfterClear_raisesAgain() {
        var p = policy()
        _ = p.step(.tick, now: 31)
        _ = p.step(.audibleChunk, now: 40)
        XCTAssertEqual(p.step(.tick, now: 69), .none)
        XCTAssertEqual(p.step(.tick, now: 70), .raise(silentFor: 30))
    }

    func test_audibleChunkWithoutRaise_returnsNone() {
        var p = policy()
        XCTAssertEqual(p.step(.audibleChunk, now: 5), .none)
    }

    func test_lastSessionClosing_clearsRaisedAlarm() {
        var p = policy()
        _ = p.step(.tick, now: 31)
        XCTAssertEqual(p.step(.sessionsOpen(false), now: 35), .clear(.sessionsClosed))
        XCTAssertEqual(p.step(.tick, now: 500), .none)
    }

    func test_noSessionOpen_neverRaises() {
        var p = policy(open: false)
        XCTAssertEqual(p.step(.tick, now: 1000), .none)
    }

    func test_sessionOpenTransition_restartsClock() {
        var p = policy(open: false)
        _ = p.step(.tick, now: 100)
        _ = p.step(.sessionsOpen(true), now: 100)
        XCTAssertEqual(p.step(.tick, now: 129), .none)
        XCTAssertEqual(p.step(.tick, now: 130), .raise(silentFor: 30))
    }

    func test_reportingSessionsOpenAgain_doesNotRestartClock() {
        var p = policy()
        _ = p.step(.sessionsOpen(true), now: 20)
        XCTAssertEqual(p.step(.tick, now: 30), .raise(silentFor: 30))
    }

    func test_audibleChunkBeforeSessionOpen_isIgnored() {
        var p = policy(open: false)
        _ = p.step(.audibleChunk, now: 10)
        _ = p.step(.sessionsOpen(true), now: 10)
        XCTAssertEqual(p.step(.tick, now: 40), .raise(silentFor: 30))
    }

    func test_disabled_neverRaises() {
        var p = policy(enabled: false)
        XCTAssertEqual(p.step(.tick, now: 1000), .none)
        XCTAssertFalse(p.isRaised)
    }

    func test_disablingWhileRaised_clearsAndStaysQuiet() {
        var p = policy()
        _ = p.step(.tick, now: 31)
        XCTAssertEqual(p.step(.config(SilenceAlarmConfig(enabled: false, seconds: 30)), now: 32), .clear(.disabled))
        XCTAssertEqual(p.step(.tick, now: 100), .none)
    }

    func test_enablingDuringLongSilence_raisesAtNextTick() {
        var p = policy(enabled: false)
        _ = p.step(.config(SilenceAlarmConfig(enabled: true, seconds: 30)), now: 50)
        XCTAssertEqual(p.step(.tick, now: 52), .raise(silentFor: 52))
    }

    func test_durationChange_appliesAtNextTick() {
        var p = policy(seconds: 30)
        _ = p.step(.config(SilenceAlarmConfig(enabled: true, seconds: 10)), now: 5)
        XCTAssertEqual(p.step(.tick, now: 10), .raise(silentFor: 10))
    }

    func test_longerDuration_delaysRaise() {
        var p = policy(seconds: 10)
        _ = p.step(.config(SilenceAlarmConfig(enabled: true, seconds: 60)), now: 5)
        XCTAssertEqual(p.step(.tick, now: 59), .none)
        XCTAssertEqual(p.step(.tick, now: 60), .raise(silentFor: 60))
    }

    func test_durationChangeWhileRaised_doesNotReRaise() {
        var p = policy()
        _ = p.step(.tick, now: 31)
        _ = p.step(.config(SilenceAlarmConfig(enabled: true, seconds: 10)), now: 32)
        XCTAssertEqual(p.step(.tick, now: 40), .none)
    }
}
