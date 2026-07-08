import AVFoundation
import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

/// Regression coverage for CanonicalPCMConverter's input-block contract: the converter
/// must deliver each input buffer exactly once per convert() call. A buggy input block
/// that unconditionally returns .haveData with the same buffer gets pulled multiple times
/// during rate conversion, duplicating input and splicing the stream.
final class CanonicalPCMConverterTests: XCTestCase {

    // MARK: - Test 1: stream continuity across reused render memory

    func test_streamContinuity_acrossReusedRenderMemory() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!

        let frameCount = 960
        let byteCount = frameCount * MemoryLayout<Float>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { raw.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteCount),
            mData: raw
        )

        let converter = CanonicalPCMConverter()
        var output = Data()

        // Continuous triangle wave, period 0.2s, amplitude 0.8, sampled at 48kHz across
        // 200 iterations of 960 frames each — simulates a persistent render buffer that
        // gets overwritten with the next chunk of a continuous signal each callback.
        let sampleRate = 48_000.0
        let period = 0.2
        let amplitude: Float = 0.8
        var sampleIndex = 0

        for _ in 0..<200 {
            let samples = raw.bindMemory(to: Float.self, capacity: frameCount)
            for i in 0..<frameCount {
                let t = Double(sampleIndex + i) / sampleRate
                let phase = (t.truncatingRemainder(dividingBy: period)) / period
                let triangle = phase < 0.5 ? (4.0 * phase - 1.0) : (3.0 - 4.0 * phase)
                samples[i] = Float(triangle) * amplitude
            }
            sampleIndex += frameCount

            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: abl.unsafeMutablePointer,
                deallocator: nil
            ) else {
                XCTFail("could not wrap AudioBufferList as AVAudioPCMBuffer")
                return
            }
            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

            guard let chunk = converter.convert(pcmBuffer) else {
                XCTFail("convert returned nil")
                return
            }
            output.append(chunk.pcm)
        }

        let sampleCount = output.count / 2
        let outputSamples: [Int16] = output.withUnsafeBytes { rawBuf in
            let buf = rawBuf.bindMemory(to: Int16.self)
            return Array(buf.prefix(sampleCount))
        }

        // (a) Frame conservation: 200 iterations * 960 frames * 16000/48000 == 64000.
        // The bug fabricated one extra frame per call (~64200).
        XCTAssertEqual(
            Double(outputSamples.count), 64_000, accuracy: 32,
            "total output frames should track input duration; large deviation indicates duplicated input"
        )

        // (b) Continuity: no adjacent-sample jump beyond what a legit triangle wave at this
        // amplitude/period could produce, excluding the converter's startup transient.
        // Legit triangle max delta ≈ 33; the bug produced deltas up to ~11000.
        let startIndex = 16
        guard outputSamples.count > startIndex else {
            XCTFail("not enough output samples to check continuity")
            return
        }
        var maxDelta = 0
        var violations = 0
        for i in (startIndex + 1)..<outputSamples.count {
            let delta = abs(Int(outputSamples[i]) - Int(outputSamples[i - 1]))
            if delta > maxDelta { maxDelta = delta }
            if delta >= 200 { violations += 1 }
        }
        XCTAssertLessThan(maxDelta, 200, "adjacent-sample delta should stay small for a continuous triangle wave")
        XCTAssertEqual(violations, 0, "no sample-to-sample discontinuities should exceed the threshold")

        // (c) Signal actually present.
        let observedPeak = outputSamples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(observedPeak, 20_000, "peak should reflect the ~0.8 amplitude signal")
    }

    // MARK: - Test 1b: fractional resample ratio with reused render memory

    /// Regression coverage for the output-capacity bug: with a fractional resample ratio
    /// (512 frames @48kHz → 170.67 frames @16kHz), an undersized output buffer can make
    /// convert() stop before fully draining the input, retaining an unconsumed input tail.
    /// Since the input aliases reused render memory (bufferListNoCopy, same pattern as the
    /// worker's real render buffer), that retained tail is later read back as garbage —
    /// audible as periodic clicks. Integer ratios (960→320, covered by the test above)
    /// always drain fully and never exercise this path.
    func test_streamContinuity_fractionalRatio_512frameBuffers() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!

        let frameCount = 512
        let byteCount = frameCount * MemoryLayout<Float>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { raw.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteCount),
            mData: raw
        )

        let converter = CanonicalPCMConverter()
        var output = Data()

        // Continuous 500Hz sine, amplitude 0.5, sampled at 48kHz across 600 iterations of
        // 512 frames each — same reused-render-memory pattern as the 960-frame test, but
        // with a fractional resample ratio so the converter doesn't always drain evenly.
        let sampleRate = 48_000.0
        let frequency = 500.0
        let amplitude: Float = 0.5
        var sampleIndex = 0

        for _ in 0..<600 {
            let samples = raw.bindMemory(to: Float.self, capacity: frameCount)
            for i in 0..<frameCount {
                let t = Double(sampleIndex + i) / sampleRate
                samples[i] = Float(sin(2.0 * Double.pi * frequency * t)) * amplitude
            }
            sampleIndex += frameCount

            guard let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: abl.unsafeMutablePointer,
                deallocator: nil
            ) else {
                XCTFail("could not wrap AudioBufferList as AVAudioPCMBuffer")
                return
            }
            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

            guard let chunk = converter.convert(pcmBuffer) else {
                XCTFail("convert returned nil")
                return
            }
            output.append(chunk.pcm)
        }

        let sampleCount = output.count / 2
        let outputSamples: [Int16] = output.withUnsafeBytes { rawBuf in
            let buf = rawBuf.bindMemory(to: Int16.self)
            return Array(buf.prefix(sampleCount))
        }

        // (a) Continuity: no adjacent-sample jump beyond what a legit 500Hz/0.5-amplitude
        // sine at 16kHz could produce, excluding the converter's startup transient. Legit
        // max delta ≈ 3200; the bug produces ~199 events with jumps >4500 (garbage read
        // from an overwritten, unconsumed input tail).
        let startIndex = 16
        guard outputSamples.count > startIndex else {
            XCTFail("not enough output samples to check continuity")
            return
        }
        var maxDelta = 0
        var violations = 0
        for i in (startIndex + 1)..<outputSamples.count {
            let delta = abs(Int(outputSamples[i]) - Int(outputSamples[i - 1]))
            if delta > maxDelta { maxDelta = delta }
            if delta > 4500 { violations += 1 }
        }
        XCTAssertLessThanOrEqual(maxDelta, 4500, "adjacent-sample delta should stay within legit sine range")
        XCTAssertEqual(violations, 0, "no sample-to-sample discontinuities should exceed the threshold")

        // (b) Frame conservation: 600 iterations * 512 frames * 16000/48000 == 102400.
        XCTAssertEqual(
            Double(outputSamples.count), 102_400, accuracy: 32,
            "total output frames should track input duration"
        )
    }

    // MARK: - Test 2: format change rebuilds and continues

    func test_formatChange_rebuildsAndContinues() {
        let converter = CanonicalPCMConverter()

        let format48kMono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!

        for _ in 0..<3 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format48kMono, frameCapacity: 960) else {
                XCTFail("could not allocate 48kHz mono buffer")
                return
            }
            buffer.frameLength = 960
            fillSine(buffer, channel: 0, sampleRate: 48_000, frequency: 440, amplitude: 0.5)
            XCTAssertNotNil(converter.convert(buffer), "expected a chunk for 48kHz mono input")
        }

        let format44kStereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!

        // The first buffer after a converter rebuild absorbs the resampler's startup
        // latency (a real AVAudioConverter behavior, not a bug) — later buffers converge
        // to the steady-state expected size, so we check the cumulative total across all
        // three calls rather than each individually.
        let inputFrameLength = 512
        var totalActualFrames = 0
        for i in 0..<3 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format44kStereo, frameCapacity: AVAudioFrameCount(inputFrameLength)) else {
                XCTFail("could not allocate 44.1kHz stereo buffer")
                return
            }
            buffer.frameLength = AVAudioFrameCount(inputFrameLength)
            fillSine(buffer, channel: 0, sampleRate: 44_100, frequency: 440, amplitude: 0.5)
            fillSine(buffer, channel: 1, sampleRate: 44_100, frequency: 440, amplitude: 0.5)

            guard let chunk = converter.convert(buffer) else {
                XCTFail("convert returned nil after format change")
                return
            }
            let actualFrames = chunk.pcm.count / AudioFormat.bytesPerFrame
            XCTAssertGreaterThan(actualFrames, 0, "chunk \(i) after format change should be non-empty")
            totalActualFrames += actualFrames
        }
        // Tolerance covers AVAudioConverter's fixed resampler group delay (observed ~6-7
        // frames at this rate pair) that a handful of calls isn't enough to fully drain —
        // still tight enough to catch gross errors like duplicated/spliced input.
        let expectedTotalFrames = Double(inputFrameLength * 3) * 16_000.0 / 44_100.0
        XCTAssertEqual(Double(totalActualFrames), expectedTotalFrames, accuracy: 10, "cumulative output frames should track resampled input duration")
    }

    // MARK: - Test 3: all-zero input has zero peak

    func test_allZeroInput_hasZeroPeak() {
        let converter = CanonicalPCMConverter()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960) else {
            XCTFail("could not allocate buffer")
            return
        }
        buffer.frameLength = 960
        // AVAudioPCMBuffer allocates zeroed memory — no explicit fill needed.

        guard let chunk = converter.convert(buffer) else {
            XCTFail("convert returned nil for all-zero input")
            return
        }
        XCTAssertEqual(chunk.peak, 0)
    }

    // MARK: - Helpers

    private func fillSine(_ buffer: AVAudioPCMBuffer, channel: Int, sampleRate: Double, frequency: Double, amplitude: Float) {
        guard let data = buffer.floatChannelData?[channel] else { return }
        let frameLength = Int(buffer.frameLength)
        for i in 0..<frameLength {
            let t = Double(i) / sampleRate
            data[i] = Float(sin(2.0 * Double.pi * frequency * t)) * amplitude
        }
    }
}
