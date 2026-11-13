import XCTest
@testable import ManbokPlatform

// MARK: - CONTRACT: HolderExclusionTests
//
// Enforces HolderExclusion's GUARANTEES: the group function, the single exclusion predicate
// (built-in OR user group), and the Settings row builder.

final class HolderExclusionTests: XCTestCase {
    func test_appGroup_chromeHelpersShareOneKey() {
        let ids = ["com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.helper.Renderer"]
        XCTAssertEqual(Set(ids.map(appGroup)), ["com.google.chrome"])
    }

    func test_appGroup_catalogEntryUsesIconBundleID() {
        XCTAssertEqual(appGroup("us.zoom.videomeeting"), "us.zoom.xos")
        XCTAssertEqual(appGroup("net.whatsapp.WhatsApp.ServiceExtension"), "net.whatsapp.whatsapp")
    }

    func test_appGroup_unknownIDStripsHelperSuffixesAndLowercases() {
        XCTAssertEqual(appGroup("com.Example.Recorder.helper"), "com.example.recorder")
        XCTAssertEqual(appGroup("com.Example.Recorder"), "com.example.recorder")
        XCTAssertEqual(appGroup("com.example.recorder.Helper.xpc"), "com.example.recorder")
    }

    func test_appGroup_emptyStaysEmpty() {
        XCTAssertEqual(appGroup(""), "")
    }

    func test_isExcluded_builtInExactAndPrefix() {
        let none = HolderExclusion()
        XCTAssertTrue(none.isExcluded("com.apple.CoreSpeech"))
        XCTAssertTrue(none.isExcluded("com.apple.Sound-Settings.Extension"))
        XCTAssertFalse(none.isExcluded("com.example.recorder"))
    }

    func test_isExcluded_userGroupCoversEveryMemberBundleID() {
        let ex = HolderExclusion(userGroups: ["com.google.chrome"])
        XCTAssertTrue(ex.isExcluded("com.google.Chrome"))
        XCTAssertTrue(ex.isExcluded("com.google.Chrome.helper"))
        XCTAssertFalse(ex.isExcluded("org.mozilla.firefox"))
    }

    func test_rows_unionOfHoldingExcludedAndSessions_oneRowPerGroup_withStates() {
        let rows = ExclusionRows.build(
            holding: [ActiveHolder(group: "us.zoom.xos", bundleID: "us.zoom.xos", displayName: "Zoom")],
            excluded: ["com.google.chrome", "com.gone.app"],
            sessions: [
                (bundleID: "com.google.Chrome.helper", displayName: "Chrome"),
                (bundleID: "com.example.recorder", displayName: "Recorder"),
                (bundleID: "us.zoom.videomeeting", displayName: "Zoom (old session)"),
            ]
        )
        XCTAssertEqual(rows.map(\.group), ["us.zoom.xos", "com.example.recorder", "com.gone.app", "com.google.chrome"])
        XCTAssertEqual(rows.map(\.state), [.usingMicNow, .inBuffer, .excluded, .excluded])
        XCTAssertEqual(rows[0].displayName, "Zoom", "holding app's name wins over a session name")
        XCTAssertEqual(rows[2].displayName, "App", "excluded app with no holder or session falls back to the last group component")
        XCTAssertFalse(rows[3].isRecording)
        XCTAssertTrue(rows[1].isRecording)
    }

    func test_rows_excludedAppStillHoldingShowsExcluded() {
        let rows = ExclusionRows.build(
            holding: [ActiveHolder(group: "com.example.recorder", bundleID: "com.example.recorder", displayName: "Recorder")],
            excluded: ["com.example.recorder"],
            sessions: []
        )
        XCTAssertEqual(rows.map(\.state), [.excluded])
    }
}
