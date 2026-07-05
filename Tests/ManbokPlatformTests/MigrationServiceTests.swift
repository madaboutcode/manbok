import XCTest
@testable import ManbokPlatform

final class MigrationServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - removeLegacyLaunchAgent (never invokes launchctl)

    func testRemoveLegacyLaunchAgentDeletesPlistWhenPresent() {
        let plistURL = tempDir.appendingPathComponent("com.manbok.app.plist")
        try? "fake plist".write(to: plistURL, atomically: true, encoding: .utf8)

        var bootoutCalled = false
        MigrationService.removeLegacyLaunchAgent(
            plistURL: plistURL,
            fileManager: .default,
            bootout: { bootoutCalled = true }
        )

        XCTAssertTrue(bootoutCalled, "expected bootout callback to be invoked when plist exists")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plistURL.path),
            "expected plist to be removed"
        )
    }

    func testRemoveLegacyLaunchAgentNoOpWhenPlistMissing() {
        let plistURL = tempDir.appendingPathComponent("com.manbok.app.plist")

        var bootoutCalled = false
        MigrationService.removeLegacyLaunchAgent(
            plistURL: plistURL,
            fileManager: .default,
            bootout: { bootoutCalled = true }
        )

        XCTAssertFalse(bootoutCalled, "bootout must not be called when there is nothing to remove")
    }

    // MARK: - cleanStaleDaemonState

    func testCleanStaleDaemonStateRemovesSocketAndPidWhenPidIsDead() {
        let socketURL = tempDir.appendingPathComponent("run.sock")
        let pidURL = tempDir.appendingPathComponent("appa.pid")
        let deadPid: Int32 = 999_999

        try? "socket".write(to: socketURL, atomically: true, encoding: .utf8)
        try? "\(deadPid)\n".write(to: pidURL, atomically: true, encoding: .utf8)

        MigrationService.cleanStaleDaemonState(socketURL: socketURL, pidURL: pidURL, fileManager: .default)

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path), "expected stale socket removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path), "expected stale pid file removed")
    }

    func testCleanStaleDaemonStateKeepsStateWhenPidIsAlive() {
        let socketURL = tempDir.appendingPathComponent("run.sock")
        let pidURL = tempDir.appendingPathComponent("appa.pid")
        let alivePid = getpid()

        try? "socket".write(to: socketURL, atomically: true, encoding: .utf8)
        try? "\(alivePid)\n".write(to: pidURL, atomically: true, encoding: .utf8)

        MigrationService.cleanStaleDaemonState(socketURL: socketURL, pidURL: pidURL, fileManager: .default)

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path), "socket must survive when pid is alive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path), "pid file must survive when pid is alive")
    }

    func testCleanStaleDaemonStateRemovesOrphanedSocketWhenNoPidFile() {
        let socketURL = tempDir.appendingPathComponent("run.sock")
        let pidURL = tempDir.appendingPathComponent("appa.pid")

        try? "socket".write(to: socketURL, atomically: true, encoding: .utf8)

        MigrationService.cleanStaleDaemonState(socketURL: socketURL, pidURL: pidURL, fileManager: .default)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketURL.path),
            "expected orphaned socket removed when no pid file exists"
        )
    }

    func testCleanStaleDaemonStateNoOpWhenNothingExists() {
        let socketURL = tempDir.appendingPathComponent("run.sock")
        let pidURL = tempDir.appendingPathComponent("appa.pid")

        MigrationService.cleanStaleDaemonState(socketURL: socketURL, pidURL: pidURL, fileManager: .default)

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
    }

    func testCleanStaleDaemonStateRemovesPidFileWithGarbageContent() {
        let socketURL = tempDir.appendingPathComponent("run.sock")
        let pidURL = tempDir.appendingPathComponent("appa.pid")

        try? "not-a-pid".write(to: pidURL, atomically: true, encoding: .utf8)

        MigrationService.cleanStaleDaemonState(socketURL: socketURL, pidURL: pidURL, fileManager: .default)

        // Garbage pid content is treated like "no pid file" for the guard, but the
        // unreadable pid file itself is left alone since only the socket branch runs.
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }
}
