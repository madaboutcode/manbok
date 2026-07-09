import CoreAudio
import XCTest
@testable import ManbokPlatform

final class CaptureDevicePolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private let t1 = Date(timeIntervalSince1970: 1001)
    private let t2 = Date(timeIntervalSince1970: 1002)

    private func app(_ bundleID: String, arrived: Date, devices: [AudioDeviceID]) -> CaptureDevicePolicy.AppDevices {
        .init(bundleID: bundleID, arrivedAt: arrived, deviceIDs: devices)
    }

    // 1. Single app, single device.
    func test_singleAppSingleDevice() {
        let demand = [app("com.example.a", arrived: t0, devices: [1])]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(1))
    }

    // 2. Shared device wins — 2 apps share device A, 1 app alone on device B.
    func test_sharedDeviceWins() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [1]),
            app("com.example.b", arrived: t0, devices: [1]),
            app("com.example.c", arrived: t1, devices: [2]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(1))
    }

    // 3. No shared device, most-recent arrival wins (R2 scenario: Zoom on USB arrives
    // first, QuickTime on builtin arrives later → builtin wins).
    func test_noSharedDevice_mostRecentArrivalWins() {
        let demand = [
            app("us.zoom.xos", arrived: t0, devices: [10]),      // USB mic, arrived first
            app("com.apple.QuickTimePlayerX", arrived: t1, devices: [20]), // builtin, arrived later
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(20))
    }

    // 4. E3: multi-device app — one app holds [A, B], B also held by another app.
    func test_multiDeviceApp_sharedDeviceWins() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [1, 2]),
            app("com.example.b", arrived: t1, devices: [2]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(2))
    }

    // 5. One unreadable + one readable → the readable app's device, never nil.
    func test_oneUnreadableOneReadable() {
        let demand = [
            app("com.example.unreadable", arrived: t0, devices: []),
            app("com.example.readable", arrived: t1, devices: [5]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(5))
    }

    // 6. Unreadable app is the latest arrival, two readable apps tie in score — the
    // tie-break ranks only the readable holders' arrivedAt, not the unreadable app's.
    func test_unreadableLatestArrival_readableAppsTieBreakIgnoresIt() {
        let demand = [
            app("com.example.z", arrived: t0, devices: [1]),   // readable, earlier
            app("com.example.q", arrived: t1, devices: [2]),   // readable, later
            app("com.example.u", arrived: t2, devices: []),    // unreadable, latest overall
        ]
        // Score ties (1 each). Tie-break by latest arrivedAt among readable holders:
        // device 1's holder arrived t0, device 2's holder arrived t1 → device 2 wins.
        // The unreadable app's t2 arrival must not affect this.
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(2))
    }

    // 7. All unreadable → nil (no device info).
    func test_allUnreadable() {
        let demand = [
            app("com.example.a", arrived: t0, devices: []),
            app("com.example.b", arrived: t1, devices: []),
        ]
        XCTAssertNil(CaptureDevicePolicy.target(demand: demand, currentTarget: nil))
    }

    // 8. Empty demand → nil.
    func test_emptyDemand() {
        XCTAssertNil(CaptureDevicePolicy.target(demand: [], currentTarget: nil))
    }

    // 9. Equal everything, cold start (no currentTarget) → lowest AudioDeviceID wins.
    func test_equalEverything_noCurrentTarget_lowestDeviceIDWins() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [5]),
            app("com.example.b", arrived: t0, devices: [3]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(3))
    }

    // 10. Determinism — same input twice → same output.
    func test_determinism() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [1, 2]),
            app("com.example.b", arrived: t1, devices: [2]),
            app("com.example.c", arrived: t2, devices: []),
        ]
        let first = CaptureDevicePolicy.target(demand: demand, currentTarget: nil)
        let second = CaptureDevicePolicy.target(demand: demand, currentTarget: nil)
        XCTAssertEqual(first, second)
    }

    // MARK: - Tie-break (§9 validation table)

    // 11. 2-way tie, currentTarget is one of the two candidates → picks the OTHER
    // device. This is the Chrome-shaped scenario: builtin (currently recording) and a
    // newly-connected BT device both tie on score/arrival; the app's own pdv# presence
    // on the new device is the signal of intent.
    func test_twoWayTie_currentTargetIsOneCandidate_picksOther() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [5]),
            app("com.example.b", arrived: t0, devices: [3]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: .device(3)), .device(5))
        // Symmetric: current on the other candidate picks back the first.
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: .device(5)), .device(3))
    }

    // 12. Cold start — currentTarget nil with a 2-way tie → falls through to lowest-ID.
    func test_twoWayTie_coldStart_fallsThroughToLowestID() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [5]),
            app("com.example.b", arrived: t0, devices: [3]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(3))
    }

    // 13. 3-way tie with currentTarget set to one of the candidates → only 2-way ties
    // get the "prefer the other" rule; a 3+-way tie falls through to lowest-ID.
    func test_threeWayTie_currentTargetSet_fallsThroughToLowestID() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [7]),
            app("com.example.b", arrived: t0, devices: [5]),
            app("com.example.c", arrived: t0, devices: [3]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: .device(7)), .device(3))
    }

    // 14. No tie at all (single top candidate) → unaffected by currentTarget, always
    // returns the single winner regardless of what currentTarget is.
    func test_noTie_currentTargetIgnored() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [1]),
            app("com.example.b", arrived: t0, devices: [1]),
            app("com.example.c", arrived: t1, devices: [2]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: nil), .device(1))
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: .device(1)), .device(1))
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: .device(2)), .device(1))
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: .systemDefault), .device(1))
    }

    // 15. currentTarget is .device but NOT among the tied candidates → treated the same
    // as no current target; falls through to lowest-ID (the "other" rule only applies
    // when currentTarget is actually one of the two tied candidates).
    func test_twoWayTie_currentTargetNotAmongCandidates_fallsThroughToLowestID() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [5]),
            app("com.example.b", arrived: t0, devices: [3]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: .device(99)), .device(3))
    }

    // 16. currentTarget is .systemDefault (not .device) with a 2-way tie → falls
    // through to lowest-ID; only a .device currentTarget can participate in the
    // "prefer the other" rule.
    func test_twoWayTie_currentTargetSystemDefault_fallsThroughToLowestID() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [5]),
            app("com.example.b", arrived: t0, devices: [3]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand, currentTarget: .systemDefault), .device(3))
    }
}
