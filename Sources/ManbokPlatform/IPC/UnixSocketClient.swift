import Darwin
import Foundation
import ManbokCore

// MARK: - CONTRACT (UnixSocketClient)
//
// GUARANTEES
// - Connects to `AppStatePaths.socketURL`, sends one command line, reads one response line.
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
        socketURL: URL = AppStatePaths.socketURL
    ) throws -> IPCResponse {
        let fd = try openClientSocket(path: socketURL.path)
        defer { close(fd) }

        writeLine(fd: fd, line: command.wireLine)
        guard let responseLine = readLine(fd: fd),
              let response = IPCResponse.parse(line: responseLine)
        else {
            throw UnixSocketError.syscall("invalid response")
        }
        return response
    }

    private static func openClientSocket(path: String) throws -> Int32 {
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