import AVFoundation
import Foundation
import UpilAppaCore

// MARK: - CONTRACT (AVAudioCapture)
//
// GUARANTEES
// - Delivers s16le 16 kHz mono PCM as Data via sink on the audio tap thread.
// - Requests microphone permission before starting AVAudioEngine.
// - Uses AppLog category capture for diagnostics.
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
    private let engine = AVAudioEngine()
    private let log = AppLog(category: .capture)

    private var converter: AVAudioConverter?
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

        try ensureMicrophoneAuthorized()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AVAudioCaptureError.converterUnavailable
        }

        self.converter = converter
        self.sink = sink
        isCapturing = true

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, inputFormat: inputFormat)
        }

        do {
            try engine.start()
        } catch {
            isCapturing = false
            self.sink = nil
            self.converter = nil
            input.removeTap(onBus: 0)
            throw AVAudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        log.info("capture started (\(inputFormat.sampleRate) Hz → \(AudioFormat.sampleRate) Hz mono)")
    }

    public func stop() {
        guard isCapturing else { return }

        isCapturing = false
        sink = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil

        log.info("capture stopped")
    }

    private func ensureMicrophoneAuthorized() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            guard granted else { throw AVAudioCaptureError.microphoneDenied }
        default:
            throw AVAudioCaptureError.microphoneDenied
        }
    }

    private func handleTap(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard isCapturing, let sink, let converter else { return }

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