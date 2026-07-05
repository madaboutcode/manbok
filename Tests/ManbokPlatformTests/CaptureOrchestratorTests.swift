import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

final class CaptureOrchestratorTests: XCTestCase {
    func testInitialStateIsIdle() {
        let orchestrator = CaptureOrchestrator(capture: NoOpCapture(), registry: SessionRegistry())
        XCTAssertFalse(orchestrator.anySessionOpen)
        XCTAssertEqual(orchestrator.micPermission, .notDetermined)
    }

    func testStartStopIsIdempotent() {
        let orchestrator = CaptureOrchestrator(capture: NoOpCapture(), registry: SessionRegistry())
        orchestrator.start()
        orchestrator.start() // second call is a no-op, not a crash
        orchestrator.stop()
        orchestrator.stop() // second call is a no-op, not a crash
        XCTAssertFalse(orchestrator.anySessionOpen)
    }

    // TODO: Exercise the arrived/departed set-diff and drain-timer paths once
    // ProcessAudioMonitor exposes a protocol seam for injecting fake process lists —
    // today it is a `final class` that reads real CoreAudio HAL state, so poll() cannot
    // be driven deterministically from a unit test.
}

private final class NoOpCapture: AudioCapturing {
    func start(sink: @escaping (Data) -> Void) throws {}
    func stop() {}
}
