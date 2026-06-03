import Foundation

func writeWav(path: URL, pcm: Data, sampleRate: UInt32 = 16_000, channels: UInt16 = 1, bitsPerSample: UInt16 = 16) throws {
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
    try (header + pcm).write(to: path)
}

extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

let pcm = Data(repeating: 0, count: 3200) // 0.1s silence
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("spike-out.wav")
try writeWav(path: out, pcm: pcm)
let bytes = try Data(contentsOf: out)
print("wrote \(out.path) (\(bytes.count) bytes)")
print("  riff: \(String(data: bytes[0..<4], encoding: .ascii) ?? "?")")
print("  format tag: \(bytes[20])") // should be 1 for PCM
print("  sample rate: \(bytes[24]) \(bytes[25]) \(bytes[26]) \(bytes[27])")