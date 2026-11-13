import CoreAudio
import XCTest
import ManbokCore
@testable import ManbokPlatform

/// H11. The microphone permission prompt must never occupy the lifecycle queue. The authorizer is a
/// fake that stays silent until the test answers; supervisor and lifecycle controller are real.
final class NoSignals: EnvironmentSignaling {
    var handler: ((EnvironmentSignal) -> Void)?
    func activate() {}
    func deactivate() { handler = nil }
    func observe(device: AudioDeviceID?) {}
}

private final class CountingWorker: PinnedAudioCapturing {
    private(set) var boundDevice: AudioDeviceID?
    func start(target: CaptureTarget, sink: @escaping (CaptureChunk) -> Void) throws { boundDevice = 77 }
    func stop() {}
}

final class LifecycleBlockingReplayTests: XCTestCase {
    private let app = HolderObservation(appID: "com.test.app", pid: 4242, inputDevices: [77])

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private struct Rig {
        let lifecycle: SessionLifecycleController
        let supervisor: CaptureSupervisor
        let authorizer: FakeMicrophoneAuthorizer
        let snapshots: Counter
        let workersMade: Counter
    }

    private func makeRig(status: MicrophoneAuthorizationStatus, pollInterval: TimeInterval) -> Rig {
        let authorizer = FakeMicrophoneAuthorizer(status: status)
        let snapshots = Counter(), workersMade = Counter()
        let registry = SessionRegistry(ringCapacity: BufferPolicy.capacityBytes(for: .min5))
        let supervisor = CaptureSupervisor(
            makeWorker: { workersMade.bump(); return CountingWorker() },
            authorizer: authorizer, signals: NoSignals(), appendSink: { registry.append($0) })
        let holder = app
        let lifecycle = SessionLifecycleController(
            supervisor: supervisor, registry: registry,
            holderSnapshot: { snapshots.bump(); return HolderSnapshot(holders: [holder], liveInputDevices: [77]) },
            permission: { .authorized }, pollInterval: pollInterval, gracePeriod: 0.3)
        supervisor.onPermissionResolved = { [weak lifecycle] in lifecycle?.permissionDidChange() }
        supervisor.start()
        lifecycle.start()
        addTeardownBlock { lifecycle.stop(); supervisor.stop() }
        return Rig(lifecycle: lifecycle, supervisor: supervisor, authorizer: authorizer,
                   snapshots: snapshots, workersMade: workersMade)
    }

    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return cond()
    }

    func test_stopReturnsAndTicksContinueWhilePromptIsOpen() {
        let rig = makeRig(status: .notDetermined, pollInterval: 0.1)
        XCTAssertTrue(waitUntil(3) { rig.authorizer.requestCount == 1 }, "first demand asks for permission")

        let before = rig.snapshots.value
        XCTAssertTrue(waitUntil(2) { rig.snapshots.value >= before + 3 }, "ticks keep running while the prompt is open")
        XCTAssertEqual(rig.authorizer.requestCount, 1, "one prompt, not one per tick")
        XCTAssertEqual(rig.workersMade.value, 0)

        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { rig.lifecycle.stop(); stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 1), .success, "stop() returned while the prompt was open")
    }

    func test_grantStepsImmediatelyAndStartsCapture() {
        // 60 s poll: only the grant-triggered step can start capture inside the wait below.
        let rig = makeRig(status: .notDetermined, pollInterval: 60)
        XCTAssertTrue(waitUntil(3) { rig.authorizer.requestCount == 1 })
        XCTAssertEqual(rig.workersMade.value, 0)

        rig.authorizer.answer(true)

        XCTAssertTrue(waitUntil(2) { rig.workersMade.value == 1 }, "capture started without waiting for the next tick")
    }

    func test_denialDoesNotGrowBackoff() {
        let authorizer = FakeMicrophoneAuthorizer(status: .denied)
        let made = Counter()
        let supervisor = CaptureSupervisor(
            makeWorker: { made.bump(); return CountingWorker() },
            authorizer: authorizer, signals: NoSignals(), appendSink: { _ in })
        let now = Date(timeIntervalSince1970: 1000)
        let demand = [DemandEntry(bundleID: "com.test.app", pid: 1, arrivedAt: now, deviceIDs: [77])]

        for _ in 0..<6 { XCTAssertFalse(supervisor.apply(demand: demand, now: now).isCapturing) }
        XCTAssertEqual(made.value, 0, "no worker is created while permission is denied")
        XCTAssertEqual(authorizer.requestCount, 0, "denied is final; no prompt is possible")

        authorizer.status = .authorized
        // Same `now`: a counted failed start would make mayRestart false here.
        XCTAssertTrue(supervisor.apply(demand: demand, now: now).isCapturing)
        XCTAssertEqual(made.value, 1)
    }
}
