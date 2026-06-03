import Foundation

// MARK: - CONTRACT (WavFileWriter)
//
// GUARANTEES
// - Writes pre-encoded WAV bytes to the given URL atomically.
// - Creates parent directories when missing.
//
// EXPECTS
// - `wavData` is already valid RIFF WAV (from WavPCMEncoder in Core).
//
// DOES NOT
// - Encode PCM, choose dump paths, or import AVFoundation.

/// Persists WAV file bytes produced by the domain encoder.
public enum WavFileWriter {
    public static func write(wavData: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        }
        try wavData.write(to: url, options: .atomic)
    }
}