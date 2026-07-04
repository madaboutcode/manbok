import XCTest
@testable import ManbokCore

final class SpeechActivityDetectorTests: XCTestCase {
    func testSilenceStaysBelowThreshold() {
        var detector = SpeechActivityDetector(minRMSThreshold: 350)
        let quiet = pcm(repeating: 50, count: 400)
        let m = detector.analyze(pcm: quiet)
        XCTAssertFalse(m.isSpeech)
        XCTAssertLessThan(m.rms, m.threshold)
    }

    func testLoudChunkIsSpeech() {
        var detector = SpeechActivityDetector(minRMSThreshold: 350)
        _ = detector.analyze(pcm: pcm(repeating: 50, count: 400))
        let m = detector.analyze(pcm: pcm(repeating: 12_000, count: 400))
        XCTAssertTrue(m.isSpeech)
    }

    private func pcm(repeating sample: Int16, count: Int) -> Data {
        var samples = [Int16](repeating: sample, count: count)
        return Data(bytes: &samples, count: samples.count * 2)
    }
}