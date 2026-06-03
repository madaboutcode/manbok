import Foundation

// 16 kHz, mono, 16-bit PCM — 10 minutes (requirements.md)
let sampleRate = 16_000
let channels = 1
let bytesPerSample = 2
let minutes = 10
let seconds = minutes * 60
let byteCount = sampleRate * channels * bytesPerSample * seconds

print("ring buffer capacity (10 min @ 16kHz mono s16le)")
print("  bytes: \(byteCount)")
print("  MB (decimal): \(String(format: "%.2f", Double(byteCount) / 1_000_000))")
print("  MB (binary):  \(String(format: "%.2f", Double(byteCount) / (1024 * 1024)))")

// Wrap index sanity
let capacity = byteCount
var writePos = capacity - 100
let chunk = 200
writePos = (writePos + chunk) % capacity
let startForLastNSeconds: (Int) -> Int = { n in
    let need = n * sampleRate * bytesPerSample
    return (writePos - need + capacity) % capacity
}
print("  last 60s start index (writePos=\(writePos)): \(startForLastNSeconds(60))")