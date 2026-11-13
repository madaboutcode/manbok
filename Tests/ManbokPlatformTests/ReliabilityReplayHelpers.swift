import XCTest
@testable import ManbokPlatform

/// Shared helpers for the T1081 reliability replay tests (H11-H27).
/// Replay tests assert the PROMISE. Where replay showed the promise is broken, the assertion is wrapped
/// in `expectKnownBug` so the suite stays green. Run with `R1_STRICT=1` to see the raw failures.
enum Replay {
    static var strict: Bool { ProcessInfo.processInfo.environment["R1_STRICT"] == "1" }
}

extension XCTestCase {
    func expectKnownBug(_ reason: String, _ body: () -> Void) {
        if Replay.strict { body() } else { XCTExpectFailure(reason, options: .init()) { body() } }
    }

    /// Short temp dir (sockaddr_un limit) installed as the AppStatePaths override for the test's lifetime.
    func installTempStateDirectory() -> URL {
        let dir = URL(fileURLWithPath: "/tmp/mbk-r1-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppStatePaths.stateDirectoryOverride = dir
        addTeardownBlock {
            AppStatePaths.stateDirectoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }
}
