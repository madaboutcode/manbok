import XCTest
@testable import ManbokPlatform

/// Contract tests for AppIdentityCatalog (see its CONTRACT block). The Chrome-helper
/// scenarios mirror the incident: a session bundleID of `com.google.Chrome.helper`
/// must yield "Chrome" as the display name and `com.google.chrome` as the first icon
/// candidate, so the icon lookup lands on the real Chrome bundle instead of the
/// faceless helper (which synthesizes the generic blank-grid icon).
final class AppIdentityCatalogTests: XCTestCase {

    // MARK: - entry(for:)

    func testEntryHitReturnsChromeHelperMapping() {
        let entry = AppIdentityCatalog.entry(for: "com.google.chrome.helper")
        XCTAssertEqual(entry?.displayName, "Chrome")
        XCTAssertEqual(entry?.iconBundleID, "com.google.chrome")
    }

    func testEntryMissReturnsNilForUnknownBundleID() {
        XCTAssertNil(AppIdentityCatalog.entry(for: "com.unknown.nonexistent-app"))
    }

    func testEntryLookupIsCaseInsensitive() {
        let entry = AppIdentityCatalog.entry(for: "COM.GOOGLE.CHROME.HELPER")
        XCTAssertEqual(entry?.displayName, "Chrome")
        XCTAssertEqual(entry?.iconBundleID, "com.google.chrome")
    }

    func testWebKitFixturesResolveToSafari() {
        for bundleID in ["com.apple.webkit.gpu", "com.apple.webkit.webcontent", "com.apple.webkit.networking"] {
            let entry = AppIdentityCatalog.entry(for: bundleID)
            XCTAssertEqual(entry?.displayName, "Safari", "\(bundleID) should resolve to Safari")
            XCTAssertEqual(entry?.iconBundleID, "com.apple.safari", "\(bundleID) icon should point at Safari's own bundle")
        }
    }

    func testEntryEmptyStringReturnsNil() {
        XCTAssertNil(AppIdentityCatalog.entry(for: ""))
    }

    // MARK: - iconCandidates(for:)

    func testIconCandidatesForChromeHelperPutsParentBundleFirst() {
        // The incident case, verbatim bundleID as captured from CoreAudio (mixed case).
        let candidates = AppIdentityCatalog.iconCandidates(for: "com.google.Chrome.helper")
        XCTAssertEqual(candidates.first, "com.google.chrome",
                        "catalog's iconBundleID must be tried before any stem or the raw ID")
        XCTAssertTrue(candidates.contains("com.google.Chrome.helper"), "raw ID must still be a fallback candidate")
        XCTAssertEqual(candidates.last, "com.google.Chrome.helper", "raw ID goes last, not first")
    }

    func testIconCandidatesHasNoDuplicates() {
        let candidates = AppIdentityCatalog.iconCandidates(for: "com.google.chrome.helper")
        XCTAssertEqual(candidates.count, Set(candidates.map { $0.lowercased() }).count,
                        "candidates must be deduplicated case-insensitively")
    }

    func testIconCandidatesForUnknownHelperIncludesStrippedStem() {
        // No catalog entry for this made-up bundle ID; must fall back to suffix stemming.
        let candidates = AppIdentityCatalog.iconCandidates(for: "com.foo.app.helper.GPU")
        XCTAssertTrue(candidates.contains("com.foo.app"),
                      "stripping '.helper.GPU' should surface the parent app stem 'com.foo.app'")
        XCTAssertEqual(candidates.last, "com.foo.app.helper.GPU", "raw (unstripped) ID must be the last resort")
        // Longest (least-stripped) stem must precede the more-stripped stem.
        let helperStemIndex = candidates.firstIndex(of: "com.foo.app.helper")
        let appStemIndex = candidates.firstIndex(of: "com.foo.app")
        XCTAssertNotNil(helperStemIndex)
        XCTAssertNotNil(appStemIndex)
        if let helperStemIndex, let appStemIndex {
            XCTAssertLessThan(helperStemIndex, appStemIndex, "longer stem must come first")
        }
    }

    func testIconCandidatesForEmptyStringIsEmpty() {
        XCTAssertEqual(AppIdentityCatalog.iconCandidates(for: ""), [])
    }

    func testIconCandidatesForPlainBundleIDWithNoSuffixesIsJustCatalogAndRaw() {
        // "us.zoom.xos" is itself the app; no suffix stripping should occur.
        let candidates = AppIdentityCatalog.iconCandidates(for: "us.zoom.xos")
        XCTAssertEqual(candidates, ["us.zoom.xos"], "catalog ID and raw ID are identical here — single candidate")
    }
}
