import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

final class OpportunisticCaptureControllerTests: XCTestCase {
    func testInitialPhaseIsWatching() {
        let service = makeDummyService()
        let controller = OpportunisticCaptureController(service: service)
        XCTAssertTrue(controller.currentPhase == .watching)
    }
}

private func makeDummyService() -> ListenerService {
    ListenerService(capture: NoOpCapture(), dumpSink: NoOpSink())
}

private final class NoOpCapture: AudioCapturing {
    func start(sink: @escaping (Data) -> Void) throws {}
    func stop() {}
}

private final class NoOpSink: DumpSink {
    func nextURL() -> URL { URL(fileURLWithPath: "/dev/null") }
    func write(wav: Data, to url: URL) throws {}
}
