import Darwin
import Foundation

// MARK: - CONTRACT (TerminalPainter)
//
// GUARANTEES
// - Paints fixed-height frames in place via cursor-up (no scroll spam).
// - Prefers stdout; falls back to /dev/tty when stdout is piped (swift run).
//
// DOES NOT
// - Write log lines or use the alternate screen buffer.

/// In-place terminal frame writer.
final class TerminalPainter {
    private let fd: Int32
    private let interactive: Bool
    private let ownsFD: Bool
    private var paintedOnce = false
    private var frameLineCount = 0

    init() {
        if isatty(STDOUT_FILENO) == 1 {
            fd = STDOUT_FILENO
            interactive = true
            ownsFD = false
        } else {
            let tty = open("/dev/tty", O_WRONLY)
            if tty >= 0, isatty(tty) == 1 {
                fd = tty
                interactive = true
                ownsFD = true
            } else {
                if tty >= 0 { close(tty) }
                fd = STDOUT_FILENO
                interactive = false
                ownsFD = false
            }
        }
        if fd == STDOUT_FILENO {
            setlinebuf(stdout)
        }
    }

    deinit {
        if ownsFD { close(fd) }
    }

    func write(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let count = lines.count

        guard interactive else {
            // Piped: one compact status line, no scroll.
            if let status = lines.first(where: { $0.contains("recording") || $0.contains("uptime") }) {
                writeRaw("\r\u{001B}[2K\(status)")
            }
            return
        }

        if !paintedOnce {
            let blob = lines.joined(separator: "\n") + "\n"
            writeRaw(blob)
            paintedOnce = true
            frameLineCount = count
        } else {
            let moveUp = max(frameLineCount, count)
            writeRaw("\u{001B}[\(moveUp)F")
            for line in lines {
                writeRaw("\u{001B}[2K\(line)\n")
            }
            frameLineCount = count
        }
    }

    func finish() {
        guard interactive, paintedOnce else { return }
        writeRaw("\n")
    }

    private func writeRaw(_ string: String) {
        guard !string.isEmpty else { return }
        string.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
    }
}

// MARK: - ANSI helpers

enum ANSIColor {
    static let reset = "\u{001B}[0m"
    static let dim = "\u{001B}[2m"
    static let bold = "\u{001B}[1m"
    static let cyan = "\u{001B}[36m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let red = "\u{001B}[31m"
    static let gray = "\u{001B}[90m"

    static func wrap(_ code: String, _ text: String) -> String {
        code + text + reset
    }
}