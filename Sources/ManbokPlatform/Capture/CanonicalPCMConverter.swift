import AVFoundation
import Foundation
import ManbokCore

// MARK: - CONTRACT (CanonicalPCMConverter)
//
// GUARANTEES
// - Converts backend-native AVAudioPCMBuffer (any rate/channels, Float32 or otherwise) to
//   canonical PCM (s16le 16kHz mono).
// - Stream continuity: the AVAudioConverter is persistent across calls to convert(_:), so
//   its internal resampler state carries forward from one buffer to the next. Each input
//   buffer is delivered to the converter EXACTLY ONCE per the AVAudioConverterInputBlock
//   pull contract — AVAudioConverter may invoke the input block multiple times within a
//   single convert() call during rate conversion; re-delivering the same buffer on a
//   second pull duplicates input and splices the stream.
// - Rebuilds the converter when the input format changes (including the first call) —
//   continuity resets across a rebuild, since a new converter has no prior state.
// - peak is the max absolute sample value in the chunk; peak == 0 iff every sample is
//   exactly zero.
// - Safe with input buffers that alias reused render memory: the input is fully consumed
//   (copied into the converter's internal state) within the convert(_:) call, so the
//   caller may reuse/overwrite the backing memory immediately after convert(_:) returns.
//   Two-layer protection: (1) here, output capacity is sized to exceed what the converter
//   could possibly produce from the input, so convert() always finishes input-dry rather
//   than stopping early with an unconsumed input tail retained; (2) in the caller
//   (AUHALWorker), render targets additionally rotate across multiple buffer lists, so
//   even a retained reference beyond this file's drain guarantee would read stable memory
//   rather than data the very next render callback overwrote.
//
// EXPECTS
// - Single-threaded caller: the worker calls convert(_:) under its own lock — this type
//   does no internal synchronization.
//
// FAILURE BEHAVIOR
// - Converter build failure, convert() error, or empty output: logged .warning, returns
//   nil — caller drops the frame and capture continues.
//
// DOES NOT
// - Retry, buffer beyond one chunk, or own capture lifecycle.

/// Converts backend-native PCM to canonical PCM (s16le 16kHz mono), preserving resampler
/// state across calls so buffer boundaries don't splice the stream.
final class CanonicalPCMConverter {
    private let log = AppLog(category: .capture)

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioFormat.sampleRate),
        channels: AVAudioChannelCount(AudioFormat.channels),
        interleaved: true
    )!

    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    /// Converts one input buffer to a canonical PCM chunk. Returns nil on any failure or
    /// empty output — caller drops the frame.
    func convert(_ buffer: AVAudioPCMBuffer) -> CaptureChunk? {
        let inputFormat = buffer.format

        if converter == nil || inputFormat != lastInputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                log.warning("dropped frame: cannot create converter for \(inputFormat)")
                return nil
            }
            converter = newConverter
            lastInputFormat = inputFormat
            log.notice(
                "converter (re)built: \(inputFormat.sampleRate)Hz ch=\(inputFormat.channelCount)"
                    + " → \(AudioFormat.sampleRate)Hz mono s16"
            )
        }

        guard let converter else { return nil }

        // Capacity must exceed the max the converter can produce from this input so
        // convert() always ends on input-dry with the ENTIRE input consumed. If capacity
        // runs out first, convert() returns with an unconsumed input tail retained inside
        // the converter/input block closure — but our input buffer can alias reused render
        // memory (bufferListNoCopy), which the next render callback overwrites, so that
        // retained tail is later read back as garbage. Integer resample ratios (e.g.
        // 960→320) always divide evenly and never hit this; fractional ratios (e.g. a
        // 512-frame 48kHz callback → 170.67 frames at 16kHz) do. rounded(.up) plus 16
        // frames of headroom covers fractional accumulation and drain jitter.
        let frameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate).rounded(.up)
        ) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            log.warning("dropped frame: could not allocate output buffer")
            return nil
        }

        // Deliver `buffer` exactly once per convert() call. AVAudioConverter may pull the
        // input block multiple times during rate conversion; re-returning the same buffer
        // on a second pull would duplicate input and splice the stream.
        var delivered = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buffer
        }

        var convError: NSError?
        converter.convert(to: out, error: &convError, withInputFrom: inputBlock)

        if let convError {
            log.warning("dropped frame: convert error — \(convError.localizedDescription)")
            return nil
        }
        guard let channel = out.int16ChannelData?[0] else {
            log.warning("dropped frame: converter output has no int16 channel data")
            return nil
        }
        let frameCount = Int(out.frameLength)
        guard frameCount > 0 else { return nil }

        var peak: Int16 = 0
        for i in 0..<frameCount {
            let sample = channel[i]
            let absSample = sample == Int16.min ? Int16.max : abs(sample)
            if absSample > peak { peak = absSample }
        }

        let byteCount = frameCount * AudioFormat.bytesPerFrame
        let pcm = Data(bytes: channel, count: byteCount)
        return CaptureChunk(pcm: pcm, peak: peak)
    }
}
