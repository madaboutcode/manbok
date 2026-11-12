import CoreAudio
import XCTest
import ManbokCore
@testable import ManbokPlatform

/// H11. AUHALWorker.start() calls MicrophoneAuthorization.ensureAuthorized() (AUHALWorker.swift:97), which
/// waits on a semaphore while the TCC prompt is open (MicrophoneAuthorization.swift:38-52). The supervisor
/// calls worker.start() from apply(), which the lifecycle controller calls on its serial queue.
/// Seam used: `makeWorker`. The fake worker blocks in start() exactly as ensureAuthorized() does; the
/// supervisor and lifecycle controller are the real types. The prompt itself cannot be shown in a test.
private final class BlockingStartWorker: PinnedAudioCapturing {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private(set) var boundDevice: AudioDeviceID?
    func start(target: CaptureTarget, sink: @escaping (CaptureChunk) -> Void) throws {
        entered.signal()
        release.wait()     // stands in for the open permission prompt
        throw PinnedCaptureError.permissionDenied
    }
    func stop() {}
}

private final class NoSignals: EnvironmentSignaling {
    var handler: ((EnvironmentSignal) -> Void)?
    func activate() {}
    func deactivate() { handler = nil }
    func observe(device: AudioDeviceID?) {}
}

final class LifecycleBlockingReplayTests: XCTestCase {
    func test_stopReturnsPromptlyWhileMicPermissionPromptIsOpen() {
        let worker = BlockingStartWorker()
        let app = AudioProcessInfo(pid: 4242, bundleID: "com.test.app", isRunningInput: true, deviceIDs: [77])
        let registry = SessionRegistry(ringCapacity: BufferPolicy.capacityBytes(for: .min5))
        let supervisor = CaptureSupervisor(
            makeWorker: { worker }, processSnapshot: { [app] in [app] },
            signals: NoSignals(), appendSink: { registry.append($0) })
        let lifecycle = SessionLifecycleController(
            supervisor: supervisor, registry: registry, processSnapshot: { [app] in [app] },
            permission: { .authorized }, pollInterval: 0.1, gracePeriod: 0.3)
        supervisor.start()
        lifecycle.start()
        addTeardownBlock { worker.release.signal(); worker.release.signal() }

        XCTAssertEqual(worker.entered.wait(timeout: .now() + 3), .success,
                       "precondition: a tick reached worker.start() and is now blocked")

        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { lifecycle.stop(); stopped.signal() }
        let result = stopped.wait(timeout: .now() + 1)
        expectKnownBug("H11: lifecycle.stop() is queue.sync on the queue the blocked tick occupies") {
            XCTAssertEqual(result, .success, "lifecycle.stop() did not return within 1 s while worker.start() was blocked")
        }
    }
}
