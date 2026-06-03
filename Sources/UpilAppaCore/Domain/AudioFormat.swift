import Foundation

// MARK: - CONTRACT: AudioFormat
//
// GUARANTEES:
// - capacityBytes == 19_200_000 for 10 minutes at the canonical PCM rate.
// - All domain math uses these constants.
//
// EXPECTS:
// - None (pure constants).
//
// FAILURE BEHAVIOR:
// - N/A (no runtime operations).
//
// DOES NOT:
// - Read hardware formats or probe the microphone.

/// Canonical PCM and ring-buffer capacity for upil-appa.
public enum AudioFormat {
    public static let sampleRate = 16_000
    public static let channels = 1
    public static let bytesPerSample = 2
    public static let bufferMinutes = 10

    public static var bytesPerFrame: Int { channels * bytesPerSample }
    public static var bytesPerSecond: Int { sampleRate * bytesPerFrame }
    public static var bytesPerMinute: Int { bytesPerSecond * 60 }
    public static let capacityBytes = bytesPerMinute * bufferMinutes
}