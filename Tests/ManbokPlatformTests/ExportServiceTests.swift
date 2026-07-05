import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

final class ExportServiceTests: XCTestCase {
    private func cleanupTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Slug sanitization

    func testSanitizeSlugLowercasesAndReplacesSpaces() {
        XCTAssertEqual(ExportService.sanitizeSlug("Audio Hijack"), "audio-hijack")
        XCTAssertEqual(ExportService.sanitizeSlug("Zoom"), "zoom")
        XCTAssertEqual(ExportService.sanitizeSlug("LM Studio"), "lm-studio")
    }

    func testSanitizeSlugEmptyStringYieldsEmpty() {
        XCTAssertEqual(ExportService.sanitizeSlug(""), "")
    }

    func testSanitizeSlugCollapsesRepeatedSeparators() {
        XCTAssertEqual(ExportService.sanitizeSlug("Foo & Bar!! Baz"), "foo-bar-baz")
    }

    // MARK: - Filename pattern

    func testNextURLProducesExpectedPattern() {
        let startTime = Date(timeIntervalSince1970: 1_700_000_000) // fixed, deterministic
        let url = ExportService.nextURL(appSlug: "Zoom", startTime: startTime)
        defer { cleanupTempFile(url) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: startTime)

        XCTAssertEqual(url.lastPathComponent, "manbok-zoom-\(timestamp).wav")
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    // MARK: - Collision suffix

    func testNextURLAvoidsCollisionsWithSuffix() {
        let startTime = Date(timeIntervalSince1970: 1_700_000_100)
        let base = ExportService.nextURL(appSlug: "collision-test", startTime: startTime)
        FileManager.default.createFile(atPath: base.path, contents: Data())
        defer { cleanupTempFile(base) }

        let second = ExportService.nextURL(appSlug: "collision-test", startTime: startTime)
        XCTAssertEqual(second.lastPathComponent.hasSuffix("-2.wav"), true)
        FileManager.default.createFile(atPath: second.path, contents: Data())
        defer { cleanupTempFile(second) }

        let third = ExportService.nextURL(appSlug: "collision-test", startTime: startTime)
        XCTAssertEqual(third.lastPathComponent.hasSuffix("-3.wav"), true)
    }

    // MARK: - writeSessionWAV

    func testWriteSessionWAVProducesValidRIFFFile() throws {
        let registry = SessionRegistry()
        let pcm = Data(repeating: 0x11, count: 1_000)
        let stableId = registry.openSession(bundleID: "com.test.app", displayName: "Test App")
        registry.append(pcm)
        registry.closeSession(bundleID: "com.test.app")

        let url = try XCTUnwrap(try ExportService.writeSessionWAV(
            stableId: stableId,
            registry: registry,
            appSlug: "test-app",
            startTime: Date()
        ))
        defer { cleanupTempFile(url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + pcm.count)
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
    }

    func testWriteSessionWAVReturnsNilForUnknownStableId() throws {
        let registry = SessionRegistry()
        let result = try ExportService.writeSessionWAV(
            stableId: 999_999,
            registry: registry,
            appSlug: "unknown",
            startTime: Date()
        )
        XCTAssertNil(result)
    }
}
