import XCTest
@testable import UpilAppaPlatform

final class OpportunisticCaptureControllerTests: XCTestCase {
    func testNoReleaseBeforeFirstSpeech() {
        XCTAssertFalse(
            OpportunisticCaptureController.shouldReleaseAfterSpeechQuiet(
                secondsSinceLastSpeech: .infinity,
                silenceBeforeRelease: 2.5
            )
        )
    }

    func testReleaseAfterSpeechQuiet() {
        XCTAssertFalse(
            OpportunisticCaptureController.shouldReleaseAfterSpeechQuiet(
                secondsSinceLastSpeech: 1.0,
                silenceBeforeRelease: 2.5
            )
        )
        XCTAssertTrue(
            OpportunisticCaptureController.shouldReleaseAfterSpeechQuiet(
                secondsSinceLastSpeech: 3.0,
                silenceBeforeRelease: 2.5
            )
        )
    }
}