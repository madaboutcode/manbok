import Darwin
import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

final class UnixSocketIPCTests: XCTestCase {
    private var socketPaths: [String] = []

    override func tearDown() {
        for path in socketPaths {
            unlink(path)
        }
        socketPaths = []
        super.tearDown()
    }

    /// Short path for `sockaddr_un.sun_path` (long TMPDIR paths fail with pathTooLong).
    private func makeSocketURL() -> URL {
        let path = "/tmp/uap-\(UUID().uuidString.prefix(8)).sock"
        socketPaths.append(path)
        return URL(fileURLWithPath: path)
    }

    func testSendPingReturnsPong() throws {
        try withServer(handler: { command in
            XCTAssertEqual(command, .ping)
            return .pong
        }, client: { socketURL in
            let response = try UnixSocketClient.send(command: .ping, socketURL: socketURL)
            XCTAssertEqual(response, .pong)
        })
    }

    func testSendSessionsReturnsParsedList() throws {
        let expected = [
            SessionSummary(
                id: 1,
                audioBytes: 10_000,
                durationSeconds: 0.6,
                startedSecondsAgo: 30,
                endedSecondsAgo: 5,
                isOpen: false,
                appName: "Zoom"
            ),
        ]
        try withServer(handler: { command in
            XCTAssertEqual(command, .sessions)
            return .sessions(expected)
        }, client: { socketURL in
            let response = try UnixSocketClient.send(command: .sessions, socketURL: socketURL)
            XCTAssertEqual(response, .sessions(expected))
        })
    }

    func testSendDumpSessionCommand() throws {
        try withServer(handler: { command in
            XCTAssertEqual(command, .dump(minutes: nil, sessionId: 3))
            return .okPath(URL(fileURLWithPath: "/tmp/session-3.wav"))
        }, client: { socketURL in
            let response = try UnixSocketClient.send(
                command: .dump(minutes: nil, sessionId: 3),
                socketURL: socketURL
            )
            XCTAssertEqual(response, .okPath(URL(fileURLWithPath: "/tmp/session-3.wav")))
        })
    }

    func testSendInvalidCommandReturnsBadCommand() throws {
        try withServer(handler: { _ in .pong }, client: { socketURL in
            let fd = try openClient(path: socketURL.path)
            defer { close(fd) }
            writeLine(fd: fd, line: "NOT-A-VERB")
            let line = try XCTUnwrap(readLine(fd: fd))
            XCTAssertEqual(IPCResponse.parse(line: line), .error(code: "bad_command", message: "bad command"))
        })
    }

    func testSendUnparseableResponseThrows() throws {
        let socketURL = makeSocketURL()
        let listenFD = try bindListen(path: socketURL.path)
        defer { close(listenFD) }

        DispatchQueue.global().async {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(listenFD, &addr, &len)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }
            _ = Self.readLine(fd: clientFD)
            Self.writeLine(fd: clientFD, line: "GARBAGE RESPONSE")
        }

        XCTAssertThrowsError(try UnixSocketClient.send(command: .ping, socketURL: socketURL)) { error in
            guard case UnixSocketError.syscall(let detail) = error else {
                return XCTFail("expected UnixSocketError.syscall, got \(error)")
            }
            XCTAssertEqual(detail, "invalid response")
        }
    }

    // MARK: - Helpers

    private func withServer(
        handler: @escaping UnixSocketServer.Handler,
        client: (URL) throws -> Void
    ) throws {
        let socketURL = makeSocketURL()
        let server = UnixSocketServer(socketURL: socketURL, handler: handler)
        let serverQueue = DispatchQueue(label: "ipc-test-server")
        var serverError: Error?

        serverQueue.async {
            do {
                try server.run()
            } catch UnixSocketError.syscall(let detail) where detail.hasPrefix("accept errno=") {
                // Expected when stop() closes the listen socket between accept calls.
            } catch {
                serverError = error
            }
        }

        waitForSocket(at: socketURL.path, timeout: 2.0)
        defer { server.stop() }

        try client(socketURL)

        server.stop()
        serverQueue.sync {}
        if let serverError { throw serverError }
    }

    private func waitForSocket(at path: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            usleep(10_000)
        }
        XCTFail("socket did not appear at \(path)")
    }

    private func openClient(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.syscall("socket errno=\(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = path.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathData.withUnsafeBufferPointer { src in
                memcpy(ptr, src.baseAddress!, src.count)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            throw UnixSocketError.syscall("connect errno=\(errno)")
        }
        return fd
    }

    private func writeLine(fd: Int32, line: String) {
        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, payload.count)
        }
    }

    private func readLine(fd: Int32) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 64)
        while buffer.count < 4096 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            for byte in chunk.prefix(n) {
                if byte == UInt8(ascii: "\n") {
                    return String(bytes: buffer, encoding: .utf8)
                }
                buffer.append(byte)
            }
        }
        guard !buffer.isEmpty else { return nil }
        return String(bytes: buffer, encoding: .utf8)
    }

    private func bindListen(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.syscall("socket errno=\(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = path.utf8CString
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathData.withUnsafeBufferPointer { src in
                memcpy(ptr, src.baseAddress!, src.count)
            }
        }

        unlink(path)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw UnixSocketError.syscall("bind errno=\(errno)")
        }
        guard listen(fd, 8) == 0 else {
            throw UnixSocketError.syscall("listen errno=\(errno)")
        }
        return fd
    }

    private static func readLine(fd: Int32) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 64)
        while buffer.count < 4096 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            for byte in chunk.prefix(n) {
                if byte == UInt8(ascii: "\n") {
                    return String(bytes: buffer, encoding: .utf8)
                }
                buffer.append(byte)
            }
        }
        guard !buffer.isEmpty else { return nil }
        return String(bytes: buffer, encoding: .utf8)
    }

    private static func writeLine(fd: Int32, line: String) {
        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, payload.count)
        }
    }
}