import XCTest
@testable import ManbokPlatform

/// Integration test for AUHALWorker — exercises the real AUHAL→AVAudioConverter→sink
/// pipeline against a live mic. Requires mic permission and a real audio device.
/// Skipped on CI (no mic). Run locally: swift test --filter AUHALWorkerIntegration
final class AUHALWorkerIntegrationTests: XCTestCase {

    private func skipOnCI() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("hardware-dependent test — requires a real mic (skipped on CI)")
        }
    }

    func test_captureProducesCanonicalPCMChunks() throws {
        try skipOnCI()

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

        let countAtStop = chunks.count
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(chunks.count, countAtStop, "no sink calls after stop()")

        XCTAssertGreaterThanOrEqual(chunks.count, 5, "should have received chunks")

        for (i, chunk) in chunks.enumerated() {
            XCTAssertFalse(chunk.pcm.isEmpty, "chunk \(i) pcm should not be empty")
            XCTAssertEqual(chunk.pcm.count % 2, 0, "chunk \(i) pcm byte count should be even (s16le)")
            let sampleCount = chunk.pcm.count / 2
            XCTAssertGreaterThan(sampleCount, 0, "chunk \(i) should have samples")
            XCTAssertLessThanOrEqual(sampleCount, 8192, "chunk \(i) should not be oversized")
        }

        // Note: some devices (BT headsets, noise-gated mics) may produce all-zero peaks
        // in a short capture window. The critical assertions above (chunks arrive, correct
        // format, stop barrier) are device-independent. Peak check is informational.
        let anySignal = chunks.contains { $0.peak != 0 }
        if !anySignal {
            print("warning: all chunks had peak=0 — device may be BT/gated (not a test failure)")
        }
    }

    func test_workerIsDisposable() throws {
        try skipOnCI()

        let worker = AUHALWorker()
        try worker.start(target: .systemDefault, sink: { _ in })
        worker.stop()

        XCTAssertNotNil(worker.boundDevice, "boundDevice stays set after stop (instance is spent)")
    }

    func test_stopIsIdempotent() throws {
        try skipOnCI()

        let worker = AUHALWorker()
        try worker.start(target: .systemDefault, sink: { _ in })
        worker.stop()
        worker.stop()
    }
}
