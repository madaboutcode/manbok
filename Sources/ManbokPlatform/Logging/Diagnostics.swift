import Foundation

// MARK: - CONTRACT (Diagnostics)
//
// GUARANTEES
// - `install` is called once at process entry (CLI or daemon bootstrap).
// - `AppLog` routes all categories through the installed sink.
//
// DOES NOT
// - Choose presentation; see DaemonRuntimeEnvironment.

public enum Diagnostics {
    private static let lock = NSLock()
    private static var sink: DiagnosticsWriting = OSLogAndStderrDiagnostics()

    public static func install(_ newSink: DiagnosticsWriting) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }

    static func emit(_ body: (DiagnosticsWriting) -> Void) {
        lock.lock()
        let current = sink
        lock.unlock()
        body(current)
    }
}