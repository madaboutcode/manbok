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

    func test_excludedApps_defaultEmpty_roundTripsAcrossInstances() {
        let first = SettingsStore(defaults: defaults)
        XCTAssertEqual(first.excludedApps, [])
        first.excludedApps = ["com.google.chrome", "us.zoom.xos"]

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.excludedApps, ["com.google.chrome", "us.zoom.xos"])
    }

    func test_excludedApps_changeNotifiesOnceWithNewSet_notOnInitOrNoOp() {
        var calls: [Set<String>] = []
        let store = SettingsStore(defaults: defaults)
        store.excludedAppsDidChange = { calls.append($0) }
        store.excludedApps = ["a"]
        store.excludedApps = ["a"]            // unchanged
        store.excludedApps = []
        XCTAssertEqual(calls, [["a"], []])
    }

    // MARK: - Silent-mic alarm

    func test_silenceAlarm_defaultsOffAt30Seconds() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.silenceAlarmEnabled, false)
        XCTAssertEqual(store.silenceAlarmSeconds, 30)
    }

    func test_silenceAlarm_roundTripsAcrossInstances() {
        let first = SettingsStore(defaults: defaults)
        first.silenceAlarmEnabled = true
        first.silenceAlarmSeconds = 120

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.silenceAlarm, SilenceAlarmConfig(enabled: true, seconds: 120))
    }

    func test_silenceAlarm_offListStoredSecondsLoadAsDefault() {
        defaults.set(45, forKey: "silenceAlarmSeconds")

        XCTAssertEqual(SettingsStore(defaults: defaults).silenceAlarmSeconds, 30)
    }

    func test_silenceAlarm_changesForwardNewConfig_initDoesNot() {
        var received: [SilenceAlarmConfig] = []
        let store = SettingsStore(defaults: defaults)
        store.silenceAlarmDidChange = { received.append($0) }

        store.silenceAlarmEnabled = true
        store.silenceAlarmSeconds = 10
        store.silenceAlarmSeconds = 10

        XCTAssertEqual(received, [
            SilenceAlarmConfig(enabled: true, seconds: 30),
            SilenceAlarmConfig(enabled: true, seconds: 10),
        ])
    }
}
