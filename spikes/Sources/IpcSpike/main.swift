import Foundation

enum SpikeError: Error { case failed(String) }

func runServer(socketPath: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SpikeError.failed("socket") }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathData = socketPath.utf8CString
    guard pathData.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        throw SpikeError.failed("path too long")
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        pathData.withUnsafeBufferPointer { src in
            memcpy(ptr, src.baseAddress!, src.count)
        }
    }

    unlink(socketPath)
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else { throw SpikeError.failed("bind errno=\(errno)") }
    guard listen(fd, 1) == 0 else { throw SpikeError.failed("listen") }

    var clientAddr = sockaddr()
    var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
    let client = accept(fd, &clientAddr, &len)
    guard client >= 0 else { throw SpikeError.failed("accept") }
    defer { close(client) }

    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(client, &buf, buf.count)
    let msg = String(bytes: buf.prefix(n), encoding: .utf8) ?? ""
    let reply = Data("ok:\(msg)".utf8)
    reply.withUnsafeBytes { write(client, $0.baseAddress!, reply.count) }
    print("server: received '\(msg.trimmingCharacters(in: .whitespacesAndNewlines))'")
}

func runClient(socketPath: String) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SpikeError.failed("socket") }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathData = socketPath.utf8CString
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
    guard connectResult == 0 else { throw SpikeError.failed("connect errno=\(errno)") }

    let msg = Data("status\n".utf8)
    msg.withUnsafeBytes { write(fd, $0.baseAddress!, msg.count) }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, buf.count)
    print("client: \(String(bytes: buf.prefix(n), encoding: .utf8) ?? "")")
}

let socketPath = "/tmp/upil-appa-spike.sock"
let mode = CommandLine.arguments.dropFirst().first ?? "client"

if mode == "server" {
    try runServer(socketPath: socketPath)
} else {
    try runClient(socketPath: socketPath)
}