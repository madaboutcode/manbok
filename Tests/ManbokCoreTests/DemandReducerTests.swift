import XCTest
@testable import ManbokCore

// MARK: - CONTRACT: DemandReducerTests
//
// Enforces DemandReducer's GUARANTEES. Each model break path of T1081 (model/README.md
// "Break paths") is one test, named after the rule it protects and the variant it kills.
// Time is a plain TimeInterval; grace is 5 s throughout.

final class DemandReducerTests: XCTestCase {
    private let reducer = DemandReducer(grace: 5)

    private func holder(_ app: String, pid: Int32 = 1, _ devices: Set<UInt32>) -> HolderObservation {
        HolderObservation(appID: app, pid: pid, inputDevices: devices)
    }

    private func input(
        _ now: TimeInterval,
        _ holders: [HolderObservation] = [],
        live: Set<UInt32> = [1, 2],
        capturing: Bool = true
    ) -> DemandInput {
        DemandInput(now: now, holders: holders, liveDevices: live, isCapturing: capturing)
    }

    /// Runs steps in order and returns the final state plus every output.
    private func run(_ steps: [DemandInput], from state: DemandState = .empty) -> (DemandState, [DemandOutput]) {
        var s = state
        var outs: [DemandOutput] = []
        for i in steps {
            let (next, out) = reducer.step(s, i)
            s = next
            outs.append(out)
        }
        return (s, outs)
    }

    private func app(_ out: DemandOutput, _ id: String) -> DemandApp? {
        out.demand.first { $0.appID == id }
    }

    // MARK: - Transitions

    func test_absentToHolding_appearsInDemandWithDevicesAndArrival() {
        let (s, outs) = run([input(10, [holder("a", pid: 7, [1])])])
        XCTAssertEqual(s.apps["a"], .holding(arrivedAt: 10, pid: 7, devices: [1]))
        XCTAssertEqual(outs[0].demand, [DemandApp(appID: "a", pid: 7, arrivedAt: 10, devices: [1], isDraining: false)])
    }

    func test_holdingRefreshesDevicesKeepsArrival() {
        let (s, outs) = run([input(10, [holder("a", [1])]), input(12, [holder("a", [2])])])
        XCTAssertEqual(s.apps["a"], .holding(arrivedAt: 10, pid: 1, devices: [2]))
        XCTAssertEqual(app(outs[1], "a")?.devices, [2])
    }

    func test_severalObservationsOfOneApp_mergeDevices() {
        let (_, outs) = run([input(10, [holder("a", pid: 1, [1]), holder("a", pid: 2, [2])])])
        XCTAssertEqual(app(outs[0], "a")?.devices, [1, 2])
        XCTAssertEqual(outs[0].demand.count, 1)
    }

    func test_holdingToDraining_keepsLastDevicesAndSetsDeadline() {
        let (s, outs) = run([input(10, [holder("a", [1])]), input(12)])
        XCTAssertEqual(s.apps["a"], .draining(arrivedAt: 10, pid: 1, kept: [1], deadline: 17))
        XCTAssertEqual(app(outs[1], "a")?.isDraining, true)
    }

    func test_drainingStaysUntilDeadline_thenCloseAtDeadline() {
        let (s, outs) = run([input(10, [holder("a", [1])]), input(12), input(16.9), input(17)])
        XCTAssertNotNil(app(outs[2], "a"), "still draining 0.1 s before the deadline")
        XCTAssertTrue(outs[2].sessionOps.isEmpty)
        XCTAssertEqual(outs[3].sessionOps, [.close(appID: "a")], "now == deadline closes")
        XCTAssertNil(s.apps["a"])
        XCTAssertFalse(s.sessionOpen.contains("a"))
        XCTAssertTrue(outs[3].demand.isEmpty)
    }

    func test_reclaimWithinGrace_keepsArrivedAtAndSession() {
        let (s, outs) = run([input(10, [holder("a", [1])]), input(12), input(14, [holder("a", [1])])])
        XCTAssertEqual(s.apps["a"], .holding(arrivedAt: 10, pid: 1, devices: [1]))
        XCTAssertTrue(s.sessionOpen.contains("a"))
        XCTAssertTrue(outs[2].sessionOps.isEmpty, "reclaim opens no new session")
    }

    func test_returnAfterClose_isFreshArrivalWithNewSession() {
        let (s, outs) = run([
            input(10, [holder("a", [1])]), input(12), input(17),
            input(20, [holder("a", [1])]),
        ])
        XCTAssertEqual(s.apps["a"], .holding(arrivedAt: 20, pid: 1, devices: [1]))
        XCTAssertEqual(outs[3].sessionOps, [.open(appID: "a", pid: 1)])
    }

    func test_stop_closesEveryOpenSessionAndForgetsApps() {
        let (s0, _) = run([input(10, [holder("a", [1]), holder("b", [2])]), input(12, [holder("b", [2])])])
        let (s, closes) = reducer.stop(s0)
        XCTAssertEqual(closes, [.close(appID: "a"), .close(appID: "b")])
        XCTAssertEqual(s, .empty)
    }

    // MARK: - Session rule

    func test_session_opensForEveryNonAbsentAppIffCapturing() {
        let (s, outs) = run([
            input(10, [holder("a", [1])], capturing: false),
            input(12, [holder("a", [1]), holder("b", [2])], capturing: true),
        ])
        XCTAssertTrue(outs[0].sessionOps.isEmpty, "no session while capture is down")
        XCTAssertEqual(outs[1].sessionOps, [.open(appID: "a", pid: 1), .open(appID: "b", pid: 1)])
        XCTAssertEqual(s.sessionOpen, ["a", "b"])
    }

    // MARK: - Break paths (model/README.md)

    /// fix-rowsess, P4: first capture start fails, the app's device list blips, capture comes up while
    /// the app is draining. A holder-only session rule left a non-absent app without a session.
    func test_P4_drainingAppGetsSessionWhenCaptureComesUp() {
        let (s, outs) = run([
            input(10, [holder("a", [1])], capturing: false),
            input(12, [], capturing: false),
            input(14, [], capturing: true),
        ])
        XCTAssertEqual(outs[2].sessionOps, [.open(appID: "a", pid: 1)])
        XCTAssertTrue(s.sessionOpen.contains("a"))
    }

    /// fix-p5union, P5: app a quits while app b holds another mic. a's kept device must not be a candidate.
    func test_P5_drainingDeviceNotCandidateWhileAnyHolderListsADevice() {
        let (_, outs) = run([
            input(10, [holder("a", [1]), holder("b", [2])]),
            input(12, [holder("b", [2])]),
        ])
        XCTAssertEqual(app(outs[1], "a")?.devices, [])
        XCTAssertEqual(app(outs[1], "b")?.devices, [2])
    }

    /// fix-stale, P5: the draining app's mic disappeared. The stale ID is dropped, session stays.
    func test_P5_staleKeptDeviceIsDropped_sessionSurvives() {
        let (s, outs) = run([
            input(10, [holder("a", [1])]),
            input(12, [], live: [2]),
        ])
        XCTAssertEqual(app(outs[1], "a")?.devices, [])
        XCTAssertTrue(s.sessionOpen.contains("a"))
    }

    /// fix-nofallback, P1: a one-poll list blip with the mic still present must keep the mic as candidate.
    func test_P1_drainingKeptDeviceIsCandidateWhenNoHolderListsOneAndDeviceIsLive() {
        let (_, outs) = run([input(10, [holder("a", [1])]), input(12, [], live: [1, 2])])
        XCTAssertEqual(app(outs[1], "a")?.devices, [1])
    }

    /// fix-gaphold / Spotifast, P2a+P2b: a tap-only process never reaches the reducer (no pdv# input
    /// device). When the real recorder stops, nothing but the drain keeps demand, and it ends.
    func test_P2_tapOnlyAppNeverGetsSession_demandEndsAfterRecorderDrains() {
        // "spotifast" is absent from holders at every poll.
        let (s, outs) = run([
            input(10, [holder("hex", [1])]),
            input(12),
            input(14),
            input(17),
        ])
        XCTAssertNil(s.apps["spotifast"])
        XCTAssertFalse(s.sessionOpen.contains("spotifast"))
        XCTAssertTrue(outs.allSatisfy { app($0, "spotifast") == nil })
        XCTAssertTrue(outs[3].demand.isEmpty, "no demand once the only holder has drained")
        XCTAssertEqual(outs[3].sessionOps, [.close(appID: "hex")])
    }

    /// fix-flag, P2a: an app never observed holding gets no session at any poll, however long.
    func test_P2a_appNeverObservedNeverGetsSession() {
        let (s, outs) = run((0..<5).map { input(TimeInterval($0) * 2, [holder("hex", [1])]) })
        XCTAssertEqual(s.sessionOpen, ["hex"])
        XCTAssertTrue(outs.flatMap(\.sessionOps).allSatisfy { $0 == .open(appID: "hex", pid: 1) })
    }

    /// Design 4b: switch to a new mic; the app's list is empty for a poll and the old mic vanished.
    /// Demand continues without devices (supervisor will have no target) and the session stays open.
    func test_4b_noKnownDevice_demandWithoutDevices_sessionStaysOpen() {
        let (s, outs) = run([
            input(10, [holder("a", [1])]),
            input(12, [], live: [2]),
        ])
        XCTAssertEqual(outs[1].demand.count, 1)
        XCTAssertEqual(outs[1].demand[0].devices, [])
        XCTAssertTrue(outs[1].sessionOps.isEmpty)
        XCTAssertTrue(s.sessionOpen.contains("a"))
    }

    /// sm-inventory H1: the app returns inside the grace window while capture is down. One session, no close.
    func test_H1_returnWithinGraceWhileNotCapturing_staysOneSession() {
        let (s, outs) = run([
            input(10, [holder("a", [1])]),
            input(12, [], capturing: false),
            input(14, [holder("a", [1])], capturing: false),
            input(16, [holder("a", [1])], capturing: true),
            input(30, [holder("a", [1])], capturing: true),
        ])
        XCTAssertEqual(outs.flatMap(\.sessionOps), [.open(appID: "a", pid: 1)], "opened once, never closed or reopened")
        XCTAssertEqual(s.apps["a"], .holding(arrivedAt: 10, pid: 1, devices: [1]))
    }

    /// Sleep: the monotonic clock jumps far past the deadline between two polls. The draining app closes.
    func test_sleep_clockJumpPastDeadlineClosesDrainingApp() {
        let (s, outs) = run([input(10, [holder("a", [1])]), input(12), input(5_000)])
        XCTAssertEqual(outs[2].sessionOps, [.close(appID: "a")])
        XCTAssertTrue(s.apps.isEmpty)
    }

    /// Sleep while the app still holds the mic: no close.
    func test_sleep_clockJumpWhileStillHolding_keepsSession() {
        let (s, outs) = run([input(10, [holder("a", [1])]), input(5_000, [holder("a", [1])])])
        XCTAssertTrue(outs[1].sessionOps.isEmpty)
        XCTAssertEqual(s.apps["a"], .holding(arrivedAt: 10, pid: 1, devices: [1]))
    }

    // MARK: - Idempotence

    func test_step_isIdempotentOnUnchangedInput() {
        let inputs = [
            input(10, [holder("a", [1]), holder("b", [2])]),
            input(12, [holder("b", [2])]),
            input(13, [holder("b", [2])], capturing: false),
        ]
        var s = DemandState.empty
        for i in inputs {
            let (once, _) = reducer.step(s, i)
            let (twice, out2) = reducer.step(once, i)
            XCTAssertEqual(once, twice)
            XCTAssertTrue(out2.sessionOps.isEmpty, "second identical step must issue no session ops")
            s = once
        }
    }

    func test_step_secondCallAfterCaptureStatusChange_opensSessionOnce() {
        let holders = [holder("a", [1])]
        let (s1, o1) = reducer.step(.empty, input(10, holders, capturing: false))
        XCTAssertTrue(o1.sessionOps.isEmpty)
        let (s2, o2) = reducer.step(s1, input(10, holders, capturing: true))
        XCTAssertEqual(o2.sessionOps, [.open(appID: "a", pid: 1)])
        let (_, o3) = reducer.step(s2, input(10, holders, capturing: true))
        XCTAssertTrue(o3.sessionOps.isEmpty)
    }
}
