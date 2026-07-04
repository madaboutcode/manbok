import XCTest
@testable import ManbokCore

final class WavEncoderTests: XCTestCase {
    /// WAV_RIFF: spike-validated RIFF layout for mono 16 kHz PCM.
    func testHeaderIsMono16kHzPCM() {
        let pcm = Data(repeating: 0, count: 3200)
        let wav = WavPCMEncoder.encode(pcm: pcm)

        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(data: wav[0 ..< 4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8 ..< 12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[12 ..< 16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: wav[36 ..< 40], encoding: .ascii), "data")

        let riffChunkSize = wav.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(riffChunkSize, 36 + UInt32(pcm.count))

        let fmtChunkSize = wav.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        XCTAssertEqual(fmtChunkSize, 16)

        let audioFormat = wav.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self) }
        XCTAssertEqual(audioFormat, 1)

        let channels = wav.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        XCTAssertEqual(channels, 1)

        let sampleRate = wav.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        XCTAssertEqual(sampleRate, 16_000)

        let dataChunkSize = wav.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        XCTAssertEqual(dataChunkSize, UInt32(pcm.count))

        XCTAssertEqual(wav.suffix(pcm.count), pcm)
    }
}