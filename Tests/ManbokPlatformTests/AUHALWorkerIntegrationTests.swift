import XCTest
@testable import ManbokPlatform

/// Integration test for AUHALWorker — exercises the real AUHAL→AVAudioConverter→sink
/// pipeline against a live mic. Requires mic permission for the test runner.
/// Validates the zero-copy AVAudioPCMBuffer wrapping + format conversion path.
final class AUHALWorkerIntegrationTests: XCTestCase {

    func test_captureProducesCanonicalPCMChunks() throws {
        let worker = AUHALWorker()
        let chunkExpectation = XCTestExpectation(description: "received chunks")

        var chunks: [CaptureChunk] = []
        let lock = NSLock()

        try worker.start(target: .systemDefault, sink: { chunk in
            lock.lock()
            chunks.append(chunk)
            if chunks.count >= 5 { chunkExpectation.fulfill() }
            lock.unlock()
        })

        XCTAssertNotNil(worker.boundDevice, "boundDevice should be set after start")

        wait(for: [chunkExpectation], timeout: 5)
        worker.stop()

        // No more chunks after stop
        let countAtStop = chunks.count
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(chunks.count, countAtStop, "no sink calls after stop()")

        // Validate chunks
        XCTAssertGreaterThanOrEqual(chunks.count, 5, "should have received chunks")

        for (i, chunk) in chunks.enumerated() {
            // PCM data is non-empty
            XCTAssertFalse(chunk.pcm.isEmpty, "chunk \(i) pcm should not be empty")
            // PCM data is s16le: byte count should be even (2 bytes per sample)
            XCTAssertEqual(chunk.pcm.count % 2, 0, "chunk \(i) pcm byte count should be even (s16le)")
            // Mono 16kHz: ~16000 samples/sec, chunks arrive ~every 256ms (4096 frames at 16kHz)
            // Each chunk should have between ~100 and ~8192 samples
            let sampleCount = chunk.pcm.count / 2
            XCTAssertGreaterThan(sampleCount, 0, "chunk \(i) should have samples")
            XCTAssertLessThanOrEqual(sampleCount, 8192, "chunk \(i) should not be oversized")
        }

        // At least one chunk should have non-zero peak (mic picks up noise floor)
        let anySignal = chunks.contains { $0.peak != 0 }
        XCTAssertTrue(anySignal, "at least one chunk should have non-zero peak (noise floor)")
    }

    func test_workerIsDisposable() throws {
        let worker = AUHALWorker()
        try worker.start(target: .systemDefault, sink: { _ in })
        worker.stop()

        // boundDevice remains set after stop (contract: "constant until stop()")
        // A second start on the same instance would preconditionFailure (disposable)
        XCTAssertNotNil(worker.boundDevice, "boundDevice stays set after stop (instance is spent)")
    }

    func test_stopIsIdempotent() throws {
        let worker = AUHALWorker()
        try worker.start(target: .systemDefault, sink: { _ in })
        worker.stop()
        worker.stop() // should not crash
    }
}
