import Darwin
import XCTest
@testable import ManbokPlatform

final class SingleInstanceTests: XCTestCase {
    func test_acquire_whileHeld_returnsNil() throws {
        let dir = installTempStateDirectory()
        let url = dir.appendingPathComponent("instance.lock")
        let first = try XCTUnwrap(InstanceLock.acquire(at: url))
        XCTAssertNil(try InstanceLock.acquire(at: url), "second acquirer must see the lock as held")
        withExtendedLifetime(first) {}
    }

    func test_acquire_afterHolderReleases_succeeds() throws {
        let dir = installTempStateDirectory()
        let url = dir.appendingPathComponent("instance.lock")
        var first: InstanceLock? = try XCTUnwrap(InstanceLock.acquire(at: url))
        XCTAssertNotNil(first)
        first = nil   // closes the fd; stands in for the holder process exiting or crashing
        XCTAssertNotNil(try InstanceLock.acquire(at: url))
    }

    func test_acquire_createsMissingStateDirectory() throws {
        let dir = installTempStateDirectory()
        let nested = dir.appendingPathComponent("fresh", isDirectory: true).appendingPathComponent("instance.lock")
        XCTAssertNotNil(try InstanceLock.acquire(at: nested))
    }

    func test_claim_whenFree_proceedsHoldingTheLock() throws {
        let dir = installTempStateDirectory()
        let url = dir.appendingPathComponent("instance.lock")
        guard case .proceed(let lock) = try SingleInstance.claim(lockURL: url, socketURL: AppStatePaths.socketURL) else {
            return XCTFail("expected .proceed")
        }
        XCTAssertNil(try InstanceLock.acquire(at: url), "claim must leave the lock held")
        withExtendedLifetime(lock) {}
    }

    func test_claim_heldAndHolderNotAnswering_exitsWithoutUnlinking() throws {
        let dir = installTempStateDirectory()
        let url = dir.appendingPathComponent("instance.lock")
        let holder = try XCTUnwrap(InstanceLock.acquire(at: url))
        // Hung first instance: socket file exists but nobody accepts. A plain file makes connect() fail.
        let sock = AppStatePaths.socketURL
        XCTAssertTrue(FileManager.default.createFile(atPath: sock.path, contents: Data("x".utf8)))

        let claim = try SingleInstance.claim(lockURL: url, socketURL: sock)

        guard case .otherUnresponsive = claim else { return XCTFail("expected .otherUnresponsive, got \(claim)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sock.path), "claim must not unlink the holder's socket")
        withExtendedLifetime(holder) {}
    }

    func test_claim_heldAndHolderListeningButHung_timesOutAsUnresponsive() throws {
        let dir = installTempStateDirectory()
        let url = dir.appendingPathComponent("instance.lock")
        let holder = try XCTUnwrap(InstanceLock.acquire(at: url))
        // Listening socket that never accepts/replies: connect succeeds (backlog), read blocks.
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = AppStatePaths.socketURL.path.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in bytes.withUnsafeBufferPointer { memcpy(p, $0.baseAddress!, bytes.count) } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listenFD, 4), 0)
        addTeardownBlock { close(listenFD) }

        let start = Date()
        let claim = try SingleInstance.claim(lockURL: url, socketURL: AppStatePaths.socketURL)

        guard case .otherUnresponsive = claim else { return XCTFail("expected .otherUnresponsive, got \(claim)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "PING must time out, not hang")
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppStatePaths.socketURL.path))
        withExtendedLifetime(holder) {}
    }
}
