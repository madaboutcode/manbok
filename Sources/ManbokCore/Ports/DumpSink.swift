import Foundation

// MARK: - CONTRACT (DumpSink)
//
// GUARANTEES
// - nextURL() returns a writable location for a dump WAV.
// - write(wav:to:) persists pre-encoded RIFF WAV bytes.
//
// EXPECTS
// - wav is from WavPCMEncoder; url is from nextURL() or a path under the same policy.
//
// FAILURE BEHAVIOR
// - write throws on disk errors; callers propagate without deleting partial files
//   (platform writer uses atomic write).
//
// DOES NOT
// - Encode PCM or read the ring buffer (see WavPCMEncoder).

/// Port for dump destination paths and WAV file persistence.
public protocol DumpSink: AnyObject {
    func nextURL() -> URL
    func write(wav: Data, to url: URL) throws
}