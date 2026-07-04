import AVFoundation
import Foundation
import ManbokCore

// MARK: - CONTRACT (AVAudioCapture)
//
// GUARANTEES
// - Delivers s16le 16 kHz mono PCM as Data via sink on the audio tap thread.
// - Requests microphone permission before starting AVAudioEngine.
// - Uses AppLog category capture for diagnostics.
// - Creates a fresh AVAudioEngine per capture session (F2).
// - Creates the format converter lazily from the first tap buffer's actual format (F1).
// - Recreates the converter if the hardware format changes mid-session.
//
// EXPECTS
// - sink handles Data on the capture thread (RecordingSession serializes).
//
// FAILURE BEHAVIOR
// - start throws if microphone permission denied or engine cannot start.
// - Converter errors: log warning, drop frame; keep listening.
// - No sink calls after stop.
//
// DOES NOT
// - Buffer more than one chunk internally, encode WAV, or perform IPC.

public enum AVAudioCaptureError: Error, LocalizedError {
    case microphoneDenied
    case converterUnavailable
    case engineStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access denied — grant in System Settings → Privacy → Microphone"
        case .converterUnavailable:
            return "Could not create audio converter for the input device"
        case .engineStartFailed(let detail):
            return "AVAudioEngine failed to start: \(detail)"
        }
    }
}

/// AVAudioEngine tap + AVAudioConverter → canonical PCM for the ring buffer.
public final class AVAudioCapture: NSObject, AudioCapturing {
    // F2: engine is created fresh per session, not reused
    private var engine: AVAudioEngine?
    private let log = AppLog(category: .capture)

    // F1: converter created lazily in first tap callback
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private var sink: ((Data) -> Void)?
    private var isCapturing = false

    private lazy var targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioFormat.sampleRate),
        channels: AVAudioChannelCount(AudioFormat.channels),
        interleaved: true
    )!

    public override init() {
        super.init()
    }

    public func start(sink: @escaping (Data) -> Void) throws {
        guard !isCapturing else { return }

        guard MicrophoneAuthorization.ensureAuthorized() else {
            throw AVAudioCaptureError.microphoneDenied
        }

        // F2: create a new engine each session — eliminates stale node/tap state
        let newEngine = AVAudioEngine()
        self.engine = newEngine

        let input = newEngine.inputNode

        self.sink = sink
        isCapturing = true

        // F1: pass nil format — let AVAudioEngine match hardware format automatically.
        // The converter is created lazily in handleTap from the first buffer's actual format.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        do {
            try newEngine.start()
        } catch {
            isCapturing = false
            self.sink = nil
            input.removeTap(onBus: 0)
            self.engine = nil
            throw AVAudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        log.info("capture started → \(AudioFormat.sampleRate) Hz mono s16 (converter created on first frame)")
    }

    public func stop() {
        guard isCapturing else { return }

        isCapturing = false
        sink = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // F2: discard engine so next session starts clean
        engine = nil

        converter = nil
        lastInputFormat = nil

        log.info("capture stopped")
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard isCapturing, let sink else { return }

        let inputFormat = buffer.format

        // F1: create or recreate converter if format changed (device reconfigured mid-session)
        if converter == nil || inputFormat != lastInputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                log.warning("dropped frame: cannot create converter for \(inputFormat)")
                return
            }
            converter = newConverter
            lastInputFormat = inputFormat
            log.info(
                "converter created: \(inputFormat.sampleRate) Hz ch=\(inputFormat.channelCount)"
                    + " → \(AudioFormat.sampleRate) Hz mono s16"
            )
        }

        guard let converter else { return }

        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
        ) + 1

        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            log.warning("dropped frame: could not allocate output buffer")
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: out, error: &error, withInputFrom: inputBlock)

        if let error {
            log.warning("dropped frame: convert error — \(error.localizedDescription)")
            return
        }

        guard let channel = out.int16ChannelData?[0] else { return }
        let frameCount = Int(out.frameLength)
        guard frameCount > 0 else { return }

        let byteCount = frameCount * AudioFormat.bytesPerFrame
        let pcm = Data(bytes: channel, count: byteCount)
        sink(pcm)
    }
}
