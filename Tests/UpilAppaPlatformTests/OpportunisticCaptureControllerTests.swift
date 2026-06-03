import XCTest
@testable import UpilAppaPlatform

final class OpportunisticCaptureControllerTests: XCTestCase {
    func testNoReleaseBeforeAnyAudio() {
        XCTAssertFalse(
            OpportunisticCaptureController.shouldRunReleaseProbe(
                secondsSinceLastSpeech: .infinity,
                secondsSinceLastActiveAudio: .infinity,
                chunkCount: 0,
                silenceBeforeRelease: 2.5
            )
        )
    }

    func testNoReleaseBeforeSpeechQuiet() {
        XCTAssertFalse(
            OpportunisticCaptureController.shouldRunReleaseProbe(
                secondsSinceLastSpeech: 1.0,
                secondsSinceLastActiveAudio: 1.0,
                chunkCount: 10,
                silenceBeforeRelease: 2.5
            )
        )
    }

    func testReleaseAfterSpeechQuiet() {
        XCTAssertTrue(
            OpportunisticCaptureController.shouldRunReleaseProbe(
                secondsSinceLastSpeech: 3.0,
                secondsSinceLastActiveAudio: 0.5,
                chunkCount: 10,
                silenceBeforeRelease: 2.5
            )
        )
    }

    func testReleaseAfterActiveQuietWithoutSpeech() {
        XCTAssertFalse(
            OpportunisticCaptureController.shouldRunReleaseProbe(
                secondsSinceLastSpeech: .infinity,
                secondsSinceLastActiveAudio: 1.0,
                chunkCount: 10,
                silenceBeforeRelease: 2.5
            )
        )
        XCTAssertTrue(
            OpportunisticCaptureController.shouldRunReleaseProbe(
                secondsSinceLastSpeech: .infinity,
                secondsSinceLastActiveAudio: 3.0,
                chunkCount: 10,
                silenceBeforeRelease: 2.5
            )
        )
    }
}