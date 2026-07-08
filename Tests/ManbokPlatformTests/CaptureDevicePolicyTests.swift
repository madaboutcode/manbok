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
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand), .device(1))
    }

    // 2. Shared device wins — 2 apps share device A, 1 app alone on device B.
    func test_sharedDeviceWins() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [1]),
            app("com.example.b", arrived: t0, devices: [1]),
            app("com.example.c", arrived: t1, devices: [2]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand), .device(1))
    }

    // 3. No shared device, most-recent arrival wins (R2 scenario: Zoom on USB arrives
    // first, QuickTime on builtin arrives later → builtin wins).
    func test_noSharedDevice_mostRecentArrivalWins() {
        let demand = [
            app("us.zoom.xos", arrived: t0, devices: [10]),      // USB mic, arrived first
            app("com.apple.QuickTimePlayerX", arrived: t1, devices: [20]), // builtin, arrived later
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand), .device(20))
    }

    // 4. E3: multi-device app — one app holds [A, B], B also held by another app.
    func test_multiDeviceApp_sharedDeviceWins() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [1, 2]),
            app("com.example.b", arrived: t1, devices: [2]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand), .device(2))
    }

    // 5. One unreadable + one readable → the readable app's device, never systemDefault.
    func test_oneUnreadableOneReadable() {
        let demand = [
            app("com.example.unreadable", arrived: t0, devices: []),
            app("com.example.readable", arrived: t1, devices: [5]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand), .device(5))
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
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand), .device(2))
    }

    // 7. All unreadable → systemDefault.
    func test_allUnreadable() {
        let demand = [
            app("com.example.a", arrived: t0, devices: []),
            app("com.example.b", arrived: t1, devices: []),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand), .systemDefault)
    }

    // 8. Empty demand → systemDefault.
    func test_emptyDemand() {
        XCTAssertEqual(CaptureDevicePolicy.target(demand: []), .systemDefault)
    }

    // 9. Equal everything (same score, same arrivedAt) → lowest AudioDeviceID wins.
    func test_equalEverything_lowestDeviceIDWins() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [5]),
            app("com.example.b", arrived: t0, devices: [3]),
        ]
        XCTAssertEqual(CaptureDevicePolicy.target(demand: demand), .device(3))
    }

    // 10. Determinism — same input twice → same output.
    func test_determinism() {
        let demand = [
            app("com.example.a", arrived: t0, devices: [1, 2]),
            app("com.example.b", arrived: t1, devices: [2]),
            app("com.example.c", arrived: t2, devices: []),
        ]
        let first = CaptureDevicePolicy.target(demand: demand)
        let second = CaptureDevicePolicy.target(demand: demand)
        XCTAssertEqual(first, second)
    }
}
