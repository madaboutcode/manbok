import XCTest
@testable import ManbokCore

final class DumpSessionSelectorTests: XCTestCase {
    private func summary(id: Int) -> SessionSummary {
        SessionSummary(
            id: id,
            audioBytes: 1000,
            durationSeconds: 1,
            startedSecondsAgo: 100,
            endedSecondsAgo: 50,
            isOpen: false
        )
    }

    func testParseNumericId() throws {
        let selector = try DumpSessionSelectorParser.parse("3").get()
        XCTAssertEqual(selector, .byId(3))
    }

    func testParseLast() throws {
        let selector = try DumpSessionSelectorParser.parse("last").get()
        XCTAssertEqual(selector, .fromEnd(offset: 0))
    }

    func testParseNegativeMeansStepsBeforeNewest() throws {
        XCTAssertEqual(try DumpSessionSelectorParser.parse("-1").get(), .fromEnd(offset: 1))
        XCTAssertEqual(try DumpSessionSelectorParser.parse("-2").get(), .fromEnd(offset: 2))
    }

    func testRejectsLastDashSyntax() {
        XCTAssertEqual(
            DumpSessionSelectorParser.parse("last-1"),
            .failure(.invalidSyntax("last-1"))
        )
    }

    func testResolveFromEnd() throws {
        let sessions = [summary(id: 1), summary(id: 2), summary(id: 3)]
        let newest = try DumpSessionSelectorParser.resolve(.fromEnd(offset: 0), in: sessions).get()
        let prev = try DumpSessionSelectorParser.resolve(.fromEnd(offset: 1), in: sessions).get()
        XCTAssertEqual(newest, 3)
        XCTAssertEqual(prev, 2)
    }

    func testResolveById() throws {
        let sessions = [summary(id: 1), summary(id: 2)]
        let id = try DumpSessionSelectorParser.resolve(.byId(1), in: sessions).get()
        XCTAssertEqual(id, 1)
    }

    func testUnknownIdFails() {
        let result = DumpSessionSelectorParser.resolve(.byId(9), in: [summary(id: 1)])
        XCTAssertEqual(result, .failure(.unknownSession(id: 9)))
    }

    func testOffsetOutOfRangeFails() {
        let result = DumpSessionSelectorParser.resolve(.fromEnd(offset: 2), in: [summary(id: 1)])
        XCTAssertEqual(result, .failure(.offsetOutOfRange(offset: 2, sessionCount: 1)))
    }
}