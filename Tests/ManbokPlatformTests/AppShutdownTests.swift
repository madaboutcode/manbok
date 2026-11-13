import CoreAudio
import XCTest
import ManbokCore
@testable import ManbokPlatform

private final class StartableWorker: PinnedAudioCapturing {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _stopCount = 0
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
    private(set) var boundDevice: AudioDeviceID?
    func start(target: CaptureTarget, sink: @escaping (CaptureChunk) -> Void) throws { started.signal() }
    func stop() { lock.lock(); _stopCount += 1; lock.unlock() }
}

final class AppShutdownTests: XCTestCase {
    private let app = HolderObservation(appID: "com.test.app", pid: 4242, inputDevices: [77])

    private func makeStack(worker: PinnedAudioCapturing) -> (SessionLifecycleController, CaptureSupervisor, SessionRegistry) {
        let registry = SessionRegistry(ringCapacity: BufferPolicy.capacityBytes(for: .min5))
        let snapshot = { [app] in HolderSnapshot(holders: [app], liveInputDevices: [77]) }
        let supervisor = CaptureSupervisor(
            makeWorker: { worker }, signals: NoSignals(), appendSink: { registry.append($0) })
        let lifecycle = SessionLifecycleController(
            supervisor: supervisor, registry: registry, holderSnapshot: snapshot,
            permission: { .authorized }, pollInterval: 0.1, gracePeriod: 0.3)
        supervisor.start()
        lifecycle.start()
        return (lifecycle, supervisor, registry)
    }

    func test_perform_normalStop_stopsWorkerAndClosesSessionsBeforeSaving() {
        let worker = StartableWorker()
        let (lifecycle, supervisor, registry) = makeStack(worker: worker)
        XCTAssertEqual(worker.started.wait(timeout: .now() + 3), .success, "precondition: capture started")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !registry.anySessionOpen { usleep(20_000) }
        XCTAssertTrue(registry.anySessionOpen, "precondition: a session is open")

        var stopsAtSave = -1
        var openAtSave = true
        AppShutdown.perform(lifecycle: lifecycle, supervisor: supervisor) {
            stopsAtSave = worker.stopCount
            openAtSave = registry.anySessionOpen
        }

        XCTAssertGreaterThanOrEqual(stopsAtSave, 1, "worker must be stopped before the checkpoint runs")
        XCTAssertFalse(openAtSave, "sessions must be closed before the checkpoint runs")
    }

    func test_perform_stopHangs_checkpointStillRunsWithinBound() {
        let worker = BlockingStartWorker()
        let (lifecycle, supervisor, _) = makeStack(worker: worker)
        addTeardownBlock { worker.release.signal(); worker.release.signal() }
        XCTAssertEqual(worker.entered.wait(timeout: .now() + 3), .success, "precondition: tick blocked in worker.start()")

        var saved = false
        let begin = Date()
        AppShutdown.perform(lifecycle: lifecycle, supervisor: supervisor) { saved = true }

        XCTAssertTrue(saved, "checkpoint must run even though lifecycle.stop() is stuck")
        XCTAssertLessThan(Date().timeIntervalSince(begin), 3.5, "bounded wait is 2 s")
    }

    func test_perform_concurrentCalls_serializeCheckpoints() {
        let worker = StartableWorker()
        let (lifecycle, supervisor, _) = makeStack(worker: worker)
        let lock = NSLock()
        var inside = 0, maxInside = 0
        let group = DispatchGroup()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) {
                AppShutdown.perform(lifecycle: lifecycle, supervisor: supervisor) {
                    lock.lock(); inside += 1; maxInside = max(maxInside, inside); lock.unlock()
                    usleep(100_000)
                    lock.lock(); inside -= 1; lock.unlock()
                }
            }
        }
        group.wait()
        XCTAssertEqual(maxInside, 1)
    }
}
