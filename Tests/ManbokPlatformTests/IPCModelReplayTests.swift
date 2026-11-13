import Darwin
import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

/// Replays the counterexample of Tests/verify/ipc (rule PingBound, kind "trickle") against the real server.
/// A client that sends one byte every 0.4 s must not hold the serialized accept loop: the request line has one total deadline.
final class IPCModelReplayTests: XCTestCase {
    override func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    private final class Box: @unchecked Sendable { var result: Result<IPCResponse, Error>? }

    func test_slowTricklingClientDoesNotBlockOtherClients() throws {
        _ = installTempStateDirectory()
        let url = AppStatePaths.socketURL
        let server = UnixSocketServer(socketURL: url) { _ in .pong }
        DispatchQueue.global().async { try? server.run() }
        addTeardownBlock { server.stop() }
        let ready = Date().addingTimeInterval(2)
        while Date() < ready, !FileManager.default.fileExists(atPath: url.path) { usleep(10_000) }

        let trickle = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = url.path.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in bytes.withUnsafeBufferPointer { memcpy(p, $0.baseAddress!, bytes.count) } }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(trickle, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(rc, 0)
        let stop = Atomic()
        DispatchQueue.global().async {
            var byte: UInt8 = UInt8(ascii: "P")   // never a newline
            while !stop.isSet { _ = write(trickle, &byte, 1); usleep(400_000) }
        }
        addTeardownBlock { stop.set(); close(trickle) }

        usleep(200_000)
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global().async {
            box.result = Result { try UnixSocketClient.send(command: .ping, socketURL: url) }
            sem.signal()
        }
        let answered = sem.wait(timeout: .now() + 3) == .success
        XCTAssertTrue(answered, "PING got no reply within 3 s while another client trickled one byte per 0.4 s")
    }
}

private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
