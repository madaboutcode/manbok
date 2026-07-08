import XCTest

// MARK: - CONTRACT: CaptureBoundaryTests
//
// PURPOSE: Machine-enforces the capture waist boundary (docs/specs/interfaces/capture-waist.md
// VERIFICATION): SessionLifecycleController.swift — the stable half — must reference capture
// supervision ONLY through the waist protocol (CaptureSupervising/DemandEntry/CaptureStatus/
// CaptureHealth) plus its own lifecycle vocabulary (MicPermissionState). It must never contain
// worker types, policy types, backend types, or device types — those belong to the volatile
// half behind the waist.

final class CaptureBoundaryTests: XCTestCase {
    func test_sessionLifecycle_referencesOnlyWaistSymbols() throws {
        // Path relative to this test file
        let testFilePath = URL(fileURLWithPath: #filePath)
        let projectRoot = testFilePath
            .deletingLastPathComponent()  // ManbokPlatformTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // project root
        let targetFile = projectRoot
            .appendingPathComponent("Sources/ManbokPlatform/Capture/SessionLifecycleController.swift")

        let source = try String(contentsOf: targetFile, encoding: .utf8)

        // Denylisted identifiers: capture-side vocabulary that must NOT appear
        let denylist = [
            "CaptureSupervisor",       // the concrete class, not the protocol
            "PinnedAudioCapture",      // worker class name prefix
            "PinnedAudioCapturing",    // worker protocol
            "CaptureChunk",
            "CaptureTarget",
            "CaptureDevicePolicy",
            "SilenceRecoveryPolicy",
            "CaptureRestartPolicy",
            "EnvironmentSignal",       // the enum (not the protocol)
            "EnvironmentSignaling",    // the protocol — capture-side, not lifecycle
            "InputDeviceObserver",
            "AudioDeviceID",
            "AVAudioEngine",
            "AVCaptureSession",
            "AudioUnit",
        ]

        for symbol in denylist {
            XCTAssertFalse(
                source.contains(symbol),
                "SessionLifecycleController.swift must not reference capture-side symbol '\(symbol)' — waist boundary violation"
            )
        }

        // Sanity: verify allowed symbols ARE present (the file uses the waist, and its own
        // lifecycle-side vocabulary — MicPermissionState is a lifecycle concept, not a
        // capture-side one, defined in this file).
        XCTAssertTrue(source.contains("CaptureSupervising"), "Expected waist protocol reference")
        XCTAssertTrue(source.contains("CaptureStatus"), "Expected waist status reference")
        XCTAssertTrue(source.contains("DemandEntry"), "Expected waist demand reference")
        XCTAssertTrue(source.contains("MicPermissionState"), "Expected lifecycle permission-state reference")
    }
}
