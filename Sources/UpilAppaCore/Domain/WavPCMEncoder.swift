import Foundation

// MARK: - CONTRACT: WavPCMEncoder
//
// GUARANTEES:
// - Output is standard RIFF WAVE: PCM format tag 1, mono 16 kHz, 16-bit little-endian samples.
// - fmt chunk size is 16; data chunk size equals pcm.count.
// - Total length is 44-byte header plus pcm.count.
//
// EXPECTS:
// - pcm is already in canonical format (AudioFormat: 16 kHz mono s16le).
//
// FAILURE BEHAVIOR:
// - N/A (pure transform; empty pcm yields valid header-only WAV).
//
// DOES NOT:
// - Write files, validate frame alignment, or resample audio.

/// Pure encoding of PCM `Data` → WAV file bytes (RIFF + fmt + data).
public enum WavPCMEncoder {
    private static let bitsPerSample: UInt16 = UInt16(AudioFormat.bytesPerSample * 8)

    /// Encodes raw PCM bytes into a complete in-memory WAV file.
    public static func encode(pcm: Data) -> Data {
        let sampleRate = UInt32(AudioFormat.sampleRate)
        let channels = UInt16(AudioFormat.channels)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndian: UInt32(36 + UInt32(pcm.count)))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndian: UInt32(16))
        header.append(littleEndian: UInt16(1)) // PCM
        header.append(littleEndian: channels)
        header.append(littleEndian: sampleRate)
        header.append(littleEndian: byteRate)
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.append(littleEndian: UInt32(pcm.count))
        var wav = header
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}