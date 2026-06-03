import XCTest
@testable import UpilAppaPlatform

final class DumpPathsTests: XCTestCase {
    func testNextURLInTemporaryDirectory() {
        let url = DumpPaths.nextURL()
        let temp = FileManager.default.temporaryDirectory

        XCTAssertTrue(
            url.path.hasPrefix(temp.path),
            "expected path prefix \(temp.path), got \(url.path)"
        )
        XCTAssertTrue(
            url.lastPathComponent.contains("upil-appa-"),
            "expected filename to contain upil-appa-, got \(url.lastPathComponent)"
        )
        XCTAssertEqual(url.pathExtension, "wav")
    }
}