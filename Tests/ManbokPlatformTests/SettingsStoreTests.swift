import XCTest
@testable import ManbokPlatform
import ManbokCore

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ai.manbok.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_defaultValues_onFreshSuite() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.bufferPreset, .min10)
        XCTAssertEqual(store.startAtLogin, false)
    }

    func test_bufferPreset_roundTripsAcrossInstances() {
        let first = SettingsStore(defaults: defaults)
        first.bufferPreset = .min30

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.bufferPreset, .min30)
    }

    func test_startAtLogin_roundTripsAcrossInstances() {
        let first = SettingsStore(defaults: defaults)
        first.startAtLogin = true

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.startAtLogin, true)
    }

    func test_invalidStoredPreset_fallsBackToDefault() {
        defaults.set("not-a-real-preset", forKey: "bufferPreset")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.bufferPreset, .min10)
    }
}
