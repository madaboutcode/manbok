import Darwin
import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

nonisolated(unsafe) private var sigpipeCount = 0

/// Replays second-instance, H23 and H25 from sm-inventory.md against the real UnixSocketServer/Client.
final class IPCReliabilityReplayTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Keep the test process alive when the server writes to a closed peer (see H25 test for the real check).
        signal(SIGPIPE, SIG_IGN)
    }

    private func startServer(socketURL: URL = AppStatePaths.socketURL,
                             handler: @escaping UnixSocketServer.Handler = { _ in .pong }) -> UnixSocketServer {
        let server = UnixSocketServer(socketURL: socketURL, handler: handler)
        DispatchQueue.global().async { try? server.run() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !FileManager.default.fileExists(atPath: socketURL.path) { usleep(10_000) }
        addTeardownBlock { server.stop() }
        return server
    }

    private func connectRaw(_ url: URL) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = url.path.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in bytes.withUnsafeBufferPointer { memcpy(p, $0.baseAddress!, bytes.count) } }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0)
        return fd
    }

    /// Runs `send` on a background thread; returns nil if no result within `timeout`.
    private func sendWithTimeout(_ cmd: IPCCommand, socketURL: URL, timeout: TimeInterval) -> Result<IPCResponse, Error>? {
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global().async {
            box.result = Result { try UnixSocketClient.send(command: cmd, socketURL: socketURL) }
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .success ? box.result : nil
    }
    private final class Box: @unchecked Sendable { var result: Result<IPCResponse, Error>? }

    // Second instance. A second launch must neither clear state nor unlink the live socket (B2).
    func test_secondLaunchDoesNotMakeRunningInstanceUnreachable() throws {
        _ = installTempStateDirectory()
        let lock1 = try XCTUnwrap(InstanceLock.acquire(at: AppStatePaths.lockURL))   // instance 1 owns the lock...
        _ = startServer()                                                            // ...and the socket
        let before = sendWithTimeout(.ping, socketURL: AppStatePaths.socketURL, timeout: 2)
        XCTAssertEqual(try before?.get(), .pong, "precondition: instance 1 reachable")

        let claim = try SingleInstance.claim()   // what instance 2 does first at launch
        guard case .otherRunning = claim else { return XCTFail("expected .otherRunning, got \(claim)") }

        let after = sendWithTimeout(.ping, socketURL: AppStatePaths.socketURL, timeout: 2)
        XCTAssertEqual(try after?.get(), .pong, "instance 1 must still answer PING after a second launch")
        withExtendedLifetime(lock1) {}
    }

    // H23.
    func test_idleClientDoesNotBlockOtherClients() throws {
        _ = installTempStateDirectory()
        let url = AppStatePaths.socketURL
        _ = startServer(socketURL: url)
        let idle = connectRaw(url)          // connects, sends nothing
        addTeardownBlock { close(idle) }

        // Server drops the idle client after its 1 s read timeout, then serves STATUS.
        let reply = sendWithTimeout(.status, socketURL: url, timeout: 3)
        XCTAssertNotNil(reply, "STATUS got no reply within 3 s while another client sat idle")
    }

    // Non-reading client: request sent, reply (larger than the socket buffers) never read, so the server's write blocks.
    func test_nonReadingClientDoesNotBlockOtherClients() throws {
        _ = installTempStateDirectory()
        let url = AppStatePaths.socketURL
        let big = String(repeating: "a", count: 512 * 1024)
        _ = startServer(socketURL: url) { command in
            command == .status ? .error(code: "big", message: big) : .pong
        }
        let stuck = connectRaw(url)
        addTeardownBlock { close(stuck) }
        _ = "STATUS\n".withCString { write(stuck, $0, 7) }   // then never read

        let reply = sendWithTimeout(.ping, socketURL: url, timeout: 3)
        XCTAssertEqual(try reply?.get(), .pong, "PING got no reply within 3 s while another client never read its reply")
    }

    // H25. Detect SIGPIPE delivery with a counting handler instead of dying (default disposition = terminate).
    func test_clientDisconnectingBeforeReplyDoesNotRaiseSIGPIPE() throws {
        _ = installTempStateDirectory()
        let url = AppStatePaths.socketURL
        sigpipeCount = 0
        let old = signal(SIGPIPE) { _ in sigpipeCount += 1 }
        addTeardownBlock { signal(SIGPIPE, old) }
        _ = startServer(socketURL: url) { _ in
            try? await Task.sleep(nanoseconds: 300_000_000)   // slow handler: client is gone by the time we write
            return .pong
        }
        let fd = connectRaw(url)
        let line = "PING\n"
        _ = line.withCString { write(fd, $0, 5) }
        close(fd)
        usleep(800_000)
        XCTAssertEqual(sigpipeCount, 0, "server received SIGPIPE writing to a closed client (default action kills the app)")
    }

    // CLI side of H25: the server closes the connection before the client's write lands.
    func test_clientWritingToClosedServerDoesNotRaiseSIGPIPE() throws {
        let dir = installTempStateDirectory()
        let url = dir.appendingPathComponent("c.sock")
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = url.path.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in bytes.withUnsafeBufferPointer { memcpy(p, $0.baseAddress!, bytes.count) } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listenFD, 64), 0)
        DispatchQueue.global().async {   // accept and immediately close, like a server that died mid-handshake
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 { break }
                close(fd)
            }
        }
        addTeardownBlock { close(listenFD) }

        sigpipeCount = 0
        let old = signal(SIGPIPE) { _ in sigpipeCount += 1 }
        addTeardownBlock { signal(SIGPIPE, old) }
        for _ in 0..<50 {
            XCTAssertThrowsError(try UnixSocketClient.send(command: .ping, socketURL: url))
            usleep(2_000)
        }
        XCTAssertEqual(sigpipeCount, 0, "client received SIGPIPE writing to a closed server")
    }
}
