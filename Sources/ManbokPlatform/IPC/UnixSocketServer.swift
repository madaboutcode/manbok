import Darwin
import Foundation
import ManbokCore

// MARK: - CONTRACT (UnixSocketServer)
//
// GUARANTEES
// - Listens on `AppStatePaths.socketURL` (Unix domain stream socket).
// - One request per accepted connection: read one line, invoke handler (may be async), write one response line.
// - Every accepted socket has SO_NOSIGPIPE and a 1 s send timeout. The request line must arrive completely
//   within 1 s of the read starting (one total deadline, not restarted by received bytes), and the reply must
//   be accepted by the client within 1 s per write. A client that fails either is dropped (logged at .notice)
//   and the next client is served. Worst-case delay a stuck client adds to others is therefore about 1 s per phase.
// - Requests are bare-verb UTF-8 lines; responses are NDJSON (one JSON object per line, `\n`-terminated).
//
// EXPECTS
// - Handler maps valid `IPCCommand` to `IPCResponse`; invalid commands may return `.error`.
// - State directory exists or is creatable via `AppStatePaths.ensureDirectory()`.
//
// FAILURE BEHAVIOR
// - Bind/listen/accept I/O errors propagate as `UnixSocketError`.
// - Malformed request line → handler not called; connection receives `{"type":"error","code":"bad_command",...}`.
//
// KNOWN LIMITS
// - Requests are served one at a time: a slow handler (e.g. a large DUMP writing to disk) delays every
//   other client until it returns. The timeouts bound socket I/O only, not the handler.
//
// DOES NOT
// - Stream audio, parse CLI flags, or implement dump use cases (see ManbokApp).

private final class ResponseBox: @unchecked Sendable {
    var value: IPCResponse = .error(code: "internal", message: "internal error")
}

public enum UnixSocketError: Error, Equatable, Sendable {
    case syscall(String)
    case pathTooLong
}

/// Blocking Unix domain socket server for daemon IPC.
public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCCommand) async -> IPCResponse

    private let socketURL: URL
    private let handler: Handler
    private var listenFD: Int32 = -1
    private let log = AppLog(category: .ipc)

    public init(
        socketURL: URL = AppStatePaths.socketURL,
        handler: @escaping Handler
    ) {
        self.socketURL = socketURL
        self.handler = handler
    }

    /// Binds the socket and runs an accept loop until `stop()` or an error.
    public func run() throws {
        listenFD = try Self.openListenSocket(path: socketURL.path)
        log.notice("listening on \(socketURL.path)")
        defer {
            close(listenFD)
            listenFD = -1
            unlink(socketURL.path)
            log.notice("socket server stopped")
        }

        while listenFD >= 0 {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(listenFD, &clientAddr, &len)
            if clientFD < 0 {
                if listenFD < 0 { break }
                let err = errno
                log.error("accept failed: errno=\(err)")
                throw UnixSocketError.syscall("accept errno=\(err)")
            }

            if Self.configureClientSocket(fd: clientFD) {
                Self.serveConnection(fd: clientFD, handler: handler, log: log)
            } else {
                log.notice("dropping client: already disconnected before it could be served")
            }
            close(clientFD)
        }
    }

    /// Closes the listening socket so `run()` exits the accept loop.
    public func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private static let ioTimeout = timeval(tv_sec: 1, tv_usec: 0)

    /// macOS rejects setsockopt (EINVAL) on a socket whose peer has already disconnected. Such a client
    /// cannot read a reply, so the caller drops it instead of serving it without timeouts.
    private static func configureClientSocket(fd: Int32) -> Bool {
        var on: Int32 = 1
        var tv = ioTimeout
        let results = [
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)),
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)),
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)),
        ]
        if results.allSatisfy({ $0 == 0 }) { return true }
        assert(errno == EINVAL, "unexpected setsockopt failure on accepted socket errno=\(errno)")
        return false
    }

    private static func serveConnection(fd: Int32, handler: @escaping Handler, log: AppLog) {
        let requestLine: String
        switch readLine(fd: fd) {
        case .line(let line): requestLine = line
        case .timedOut:
            log.notice("dropping client: no complete request line within 1 s")
            return
        }
        let response: IPCResponse
        if let command = IPCCommand.parse(line: requestLine) {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            Task {
                box.value = await handler(command)
                semaphore.signal()
            }
            semaphore.wait()
            response = box.value
        } else {
            response = .error(code: "bad_command", message: "bad command")
        }
        if !writeLine(fd: fd, line: response.jsonLine) {
            log.notice("dropping client: reply not delivered (client gone or not reading for 1 s)")
        }
    }

    private static func openListenSocket(path: String) throws -> Int32 {
        try AppStatePaths.ensureDirectory()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.syscall("socket errno=\(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = path.utf8CString
        guard pathData.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw UnixSocketError.pathTooLong
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathData.withUnsafeBufferPointer { src in
                memcpy(ptr, src.baseAddress!, src.count)
            }
        }

        unlink(path)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw UnixSocketError.syscall("bind errno=\(err)")
        }

        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            throw UnixSocketError.syscall("listen errno=\(err)")
        }

        return fd
    }

    /// `.line` also covers EOF or a read error before the newline: whatever arrived (possibly empty) is the line.
    private enum ReadResult {
        case line(String)
        case timedOut
    }

    /// The whole line must arrive within `totalTimeout` of the call. SO_RCVTIMEO alone restarts on every received
    /// byte, so a client sending one byte per 0.9 s would hold the serialized accept loop up to `maxBytes` seconds.
    private static func readLine(fd: Int32, maxBytes: Int = 4096, totalTimeout: TimeInterval = 1) -> ReadResult {
        var buffer = [UInt8]()
        buffer.reserveCapacity(64)
        var chunk = [UInt8](repeating: 0, count: 64)
        let deadline = ProcessInfo.processInfo.systemUptime + totalTimeout

        while buffer.count < maxBytes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return .timedOut }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32((remaining * 1000).rounded(.up)))
            if ready == 0 { return .timedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return .timedOut }
            if n <= 0 { break }
            for byte in chunk.prefix(n) {
                if byte == UInt8(ascii: "\n") {
                    return .line(String(bytes: buffer, encoding: .utf8) ?? "")
                }
                buffer.append(byte)
            }
        }
        return .line(String(bytes: buffer, encoding: .utf8) ?? "")
    }

    /// Returns false when the reply could not be fully written (peer closed, or not reading for the send timeout).
    private static func writeLine(fd: Int32, line: String) -> Bool {
        var payload = Data(line.utf8)
        payload.append(UInt8(ascii: "\n"))
        return payload.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n <= 0 { return false }
                base += n
                remaining -= n
            }
            return true
        }
    }
}
