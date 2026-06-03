import XCTest
@testable import UpilAppaCore

final class ListenerServiceTests: XCTestCase {
    func testDumpWhenEmptyReturnsError() async {
        let capture = MockAudioCapture()
        let sink = MockDumpSink()
        let service = ListenerService(capture: capture, dumpSink: sink)

        try? service.startCapture()
        XCTAssertTrue(service.isListening)

        do {
            _ = try await service.dump(minutes: nil)
            XCTFail("expected empty buffer error")
        } catch let error as ListenerError {
            XCTAssertEqual(error, .emptyBuffer)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(sink.writeCalls, 0)
    }

    func testDumpWhenNotCapturingButBufferHasData() async throws {
        let capture = MockAudioCapture()
        let sink = MockDumpSink()
        let service = ListenerService(capture: capture, dumpSink: sink)

        try service.startCapture()
        capture.deliver(Data(repeating: 0xCD, count: AudioFormat.bytesPerFrame * 50))
        service.stopCapture()
        XCTAssertFalse(service.isListening)
        XCTAssertTrue(service.hasBufferedAudio)

        let url = try await service.dump(minutes: nil)
        XCTAssertEqual(url, sink.lastURL)
        XCTAssertEqual(sink.writeCalls, 1)
    }

    func testDumpWritesWavWhenBufferHasData() async throws {
        let capture = MockAudioCapture()
        let sink = MockDumpSink()
        let service = ListenerService(capture: capture, dumpSink: sink)

        try service.startCapture()
        capture.deliver(Data(repeating: 0xAB, count: AudioFormat.bytesPerFrame * 100))

        let url = try await service.dump(minutes: nil)
        XCTAssertEqual(url, sink.lastURL)
        XCTAssertEqual(sink.writeCalls, 1)
        XCTAssertFalse(sink.lastWav?.isEmpty ?? true)
        XCTAssertEqual(sink.lastWav?.prefix(4), Data("RIFF".utf8))
    }

    func testStartCaptureWhenAlreadyListeningIsNoOp() throws {
        let capture = MockAudioCapture()
        let service = ListenerService(capture: capture, dumpSink: MockDumpSink())

        try service.startCapture()
        XCTAssertEqual(capture.startCount, 1)

        try service.startCapture()
        XCTAssertEqual(capture.startCount, 1)
    }

    func testSecondsSinceLastSpeechTracksLoudChunks() throws {
        let capture = MockAudioCapture()
        let service = ListenerService(capture: capture, dumpSink: MockDumpSink())
        try service.startCapture()

        var quiet = [Int16](repeating: 40, count: 800)
        capture.deliver(Data(bytes: &quiet, count: quiet.count * 2))
        var loud = [Int16](repeating: 12_000, count: 800)
        capture.deliver(Data(bytes: &loud, count: loud.count * 2))

        XCTAssertLessThan(service.secondsSinceLastSpeech, 0.5)
        XCTAssertTrue(service.currentActivity.isSpeech)
    }

    func testPauseForProbePreservesSpeechTimers() throws {
        let capture = MockAudioCapture()
        let service = ListenerService(capture: capture, dumpSink: MockDumpSink())
        try service.startCapture()

        var quiet = [Int16](repeating: 50, count: 400)
        capture.deliver(Data(bytes: &quiet, count: quiet.count * 2))
        var loud = [Int16](repeating: 12_000, count: 400)
        capture.deliver(Data(bytes: &loud, count: loud.count * 2))
        XCTAssertTrue(service.currentActivity.isSpeech)

        service.pauseCaptureForReleaseProbe()
        XCTAssertTrue(service.isListening)
        let quietBefore = service.secondsSinceLastSpeech
        usleep(100_000)
        XCTAssertGreaterThan(service.secondsSinceLastSpeech, quietBefore)

        try service.resumeCaptureAfterReleaseProbe()
        XCTAssertTrue(service.isListening)
        XCTAssertEqual(capture.startCount, 2)
    }

    func testStopCaptureIsIdempotent() throws {
        let capture = MockAudioCapture()
        let service = ListenerService(capture: capture, dumpSink: MockDumpSink())

        try service.startCapture()
        service.stopCapture()
        XCTAssertEqual(capture.stopCount, 1)

        service.stopCapture()
        XCTAssertEqual(capture.stopCount, 1)
    }
}

// MARK: - Mocks

private final class MockAudioCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var sink: ((Data) -> Void)?

    func start(sink: @escaping (Data) -> Void) throws {
        startCount += 1
        self.sink = sink
    }

    func stop() {
        stopCount += 1
        sink = nil
    }

    func deliver(_ data: Data) {
        sink?(data)
    }
}

private final class MockDumpSink: DumpSink {
    private(set) var writeCalls = 0
    private(set) var lastURL: URL?
    private(set) var lastWav: Data?
    private var urlCounter = 0

    func nextURL() -> URL {
        urlCounter += 1
        return URL(fileURLWithPath: "/tmp/mock-upil-appa-\(urlCounter).wav")
    }

    func write(wav: Data, to url: URL) throws {
        writeCalls += 1
        lastURL = url
        lastWav = wav
    }
}