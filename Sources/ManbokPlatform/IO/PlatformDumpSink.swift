import Foundation
import ManbokCore

// MARK: - CONTRACT (PlatformDumpSink)
//
// GUARANTEES
// - `nextURL()` delegates to `DumpPaths` (system temp + timestamped filename).
// - `write(wav:to:)` persists bytes via `WavFileWriter` (atomic write).
//
// EXPECTS
// - `wav` is pre-encoded RIFF WAV from `WavPCMEncoder`.
//
// FAILURE BEHAVIOR
// - Disk errors from `WavFileWriter.write` propagate to the dump call site.
//
// DOES NOT
// - Encode PCM, read the ring buffer, or choose non-temp paths.

/// Platform `DumpSink` using temp dump paths and atomic WAV writes.
public final class PlatformDumpSink: DumpSink {
    public init() {}

    public func nextURL() -> URL {
        DumpPaths.nextURL()
    }

    public func write(wav: Data, to url: URL) throws {
        try WavFileWriter.write(wavData: wav, to: url)
    }
}