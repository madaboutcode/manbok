import XCTest
@testable import ManbokPlatform

final class AppIdentityResolverTests: XCTestCase {
    // A pid guaranteed not to exist, so the PPID walk (tier 2) fails immediately
    // and resolution falls through deterministically to curated/cosmetic tiers.
    private let nonExistentPID: pid_t = -1

    func test_curatedLookup_isCaseInsensitive() {
        let resolver = AppIdentityResolver()
        XCTAssertEqual(resolver.resolve(bundleID: "com.Apple.FaceTime", pid: nonExistentPID), "FaceTime")
        XCTAssertEqual(resolver.resolve(bundleID: "COM.APPLE.FACETIME", pid: nonExistentPID), "FaceTime")
    }

    func test_chromeRendererSuffix_resolvesToChrome() {
        let resolver = AppIdentityResolver()
        XCTAssertEqual(resolver.resolve(bundleID: "com.google.Chrome.helper.renderer", pid: nonExistentPID), "Chrome")
    }

    func test_unknownBundleID_cosmeticFallbackTitlecases() {
        let resolver = AppIdentityResolver()
        XCTAssertEqual(resolver.resolve(bundleID: "com.example.myCoolApp", pid: nonExistentPID), "MyCoolApp")
    }

    func test_unknownBundleID_stripsHelperSuffixes() {
        let resolver = AppIdentityResolver()
        XCTAssertEqual(resolver.resolve(bundleID: "com.example.SomeApp.Helper", pid: nonExistentPID), "SomeApp")
        XCTAssertEqual(resolver.resolve(bundleID: "com.example.SomeApp.helper", pid: nonExistentPID), "SomeApp")
    }

    func test_cacheHit_resolvesSameValueOnSecondCall() {
        let resolver = AppIdentityResolver()
        let first = resolver.resolve(bundleID: "com.example.Cachable", pid: nonExistentPID)
        let second = resolver.resolve(bundleID: "com.example.Cachable", pid: nonExistentPID)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "Cachable")
    }

    func test_concurrentResolves_doNotCrash() {
        let resolver = AppIdentityResolver()
        let group = DispatchGroup()
        let bundleIDs = (0..<50).map { "com.example.concurrent\($0)" }
        for bundleID in bundleIDs {
            group.enter()
            DispatchQueue.global().async {
                _ = resolver.resolve(bundleID: bundleID, pid: self.nonExistentPID)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    }
}
