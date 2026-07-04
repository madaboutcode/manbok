import XCTest
@testable import ManbokPlatform

final class DumpPathsTests: XCTestCase {
    func testNextURLInTemporaryDirectory() {
        let url = DumpPaths.nextURL()
        let temp = FileManager.default.temporaryDirectory

        XCTAssertTrue(
            url.path.hasPrefix(temp.path),
            "expected path prefix \(temp.path), got \(url.path)"
        )
        XCTAssertTrue(
            url.lastPathComponent.contains("manbok-"),
            "expected filename to contain manbok-, got \(url.lastPathComponent)"
        )
        XCTAssertEqual(url.pathExtension, "wav")
    }
}