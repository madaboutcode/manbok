import Darwin
import Foundation
import ManbokCore

// MARK: - CONTRACT (UnixSocketServer)
//
// GUARANTEES
// - Listens on `AppStatePaths.socketURL` (Unix domain stream socket).
// - One request per accepted connection: read one line, invoke handler (may be async), write one response line.
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
// DOES NOT
// - Stream audio, parse CLI flags, or implement dump use cases (see ListenerService).

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

            Self.serveConnection(fd: clientFD, handler: handler)
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

    private static func serveConnection(fd: Int32, handler: @escaping Handler) {
        let requestLine = readLine(fd: fd) ?? ""
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
        writeLine(fd: fd, line: response.jsonLine)
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

    private static func readLine(fd: Int32, maxBytes: Int = 4096) -> String? {
        var buffer = [UInt8]()
        buffer.reserveCapacity(64)
        var chunk = [UInt8](repeating: 0, count: 64)

        while buffer.count < maxBytes {
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