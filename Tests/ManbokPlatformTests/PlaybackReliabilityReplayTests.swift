import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

/// H27. PopoverViewModel (ManbokApp executable target, no test target) decides in playSession:
///   `playingSessionId == id && !playback.isPlaying && playback.duration > 0` -> playback.resume()
/// (PopoverViewModel.swift:122). playingSessionId is never cleared when playback finishes, so this
/// replay drives the real AudioPlaybackService through a natural finish and checks (a) that the
/// view-model's condition holds on `playback`, (b) what resume() then does.
@MainActor
final class PlaybackReliabilityReplayTests: XCTestCase {
    func test_tappingPlayOnFinishedSessionPlaysItAgainFromTheStart() throws {
        let svc = AudioPlaybackService()
        let pcm = Data(count: 16_000 * 2 / 5)   // 0.2 s of 16 kHz mono s16 silence
        try svc.play(wavData: WavPCMEncoder.encode(pcm: pcm))

        let finished = expectation(description: "playback finished")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            if !svc.isPlaying { finished.fulfill() }
        }
        wait(for: [finished], timeout: 5)
        poll.invalidate()

        // View-model condition at PopoverViewModel.swift:122 on a finished player:
        XCTAssertFalse(svc.isPlaying)
        XCTAssertGreaterThan(svc.duration, 0, "so playSession takes the resume() branch")
        XCTAssertEqual(svc.currentTime, svc.duration, accuracy: 0.001, "finished: progress at end")

        svc.resume()   // what playSession calls
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let restarted = svc.isPlaying && svc.currentTime < svc.duration
        svc.stop()
        XCTAssertTrue(restarted, "resume() on a finished player must start playing from the beginning")
    }
}
