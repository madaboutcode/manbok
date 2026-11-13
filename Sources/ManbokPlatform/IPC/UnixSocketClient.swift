import Darwin
import Foundation
import ManbokCore

// MARK: - CONTRACT (UnixSocketClient)
//
// GUARANTEES
// - Writing to a server that closed the connection fails with an error, never SIGPIPE (SO_NOSIGPIPE).
// - Connects to `AppStatePaths.socketURL`, sends one command line, reads one response line.
// - With `timeout`, a send or read that makes no progress for that long fails instead of blocking.
// - Returns parsed `IPCResponse` when the reply matches the v1 protocol.
//
// EXPECTS
// - Daemon is listening on the socket path.
//
// FAILURE BEHAVIOR
// - Connect/read/write failures throw `UnixSocketError`.
// - Unparseable response line throws `UnixSocketError.syscall("invalid response")`.
//
// DOES NOT
// - Retry connections, manage daemon lifecycle, or open Audacity.

/// Short-lived Unix socket client for CLI control commands.
public enum UnixSocketClient {
    public static func send(
        command: IPCCommand,
        socketURL: URL = AppStatePaths.socketURL,
        timeout: TimeInterval? = nil
    ) throws -> IPCResponse {
        let fd = try openClientSocket(path: socketURL.path)
        defer { close(fd) }
        if let timeout { setTimeouts(fd: fd, seconds: timeout) }

        writeLine(fd: fd, line: command.wireLine)
        guard let responseLine = readLine(fd: fd),
              let response = IPCResponse.parse(line: responseLine)
        else {
            throw UnixSocketError.syscall("invalid response")
        }
        return response
    }

    private static func setTimeouts(fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        let rcv = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        let snd = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
        assert(rcv == 0 && snd == 0, "setsockopt timeouts failed errno=\(errno)")
    }

    private static func openClientSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.syscall("socket errno=\(errno)")
        }
        var on: Int32 = 1
        let nosigpipe = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        assert(nosigpipe == 0, "SO_NOSIGPIPE failed errno=\(errno)")

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

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let err = errno
            close(fd)
            throw UnixSocketError.syscall("connect errno=\(err)")
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