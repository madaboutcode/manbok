import AVFoundation
import CoreAudio
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
// - sink handles Data on the capture thread (ListenerService/SessionRegistry serializes).
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
    private var firstBufferLogged = false
    private var tapFrameCount: UInt64 = 0
    private var sinkFrameCount: UInt64 = 0
    private var peakRawRMS: Float = 0
    private var lastPeriodicLog: UInt64 = 0

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

        firstBufferLogged = false
        tapFrameCount = 0
        sinkFrameCount = 0
        peakRawRMS = 0
        lastPeriodicLog = 0

        do {
            try newEngine.start()
        } catch {
            isCapturing = false
            self.sink = nil
            input.removeTap(onBus: 0)
            self.engine = nil
            throw AVAudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        let deviceDesc = Self.actualInputDevice(input)
        log.notice("engine tapping device: \(deviceDesc)")
    }

    public func stop() {
        guard isCapturing else { return }

        isCapturing = false
        sink = nil
        firstBufferLogged = false

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        // F2: discard engine so next session starts clean
        engine = nil

        converter = nil
        lastInputFormat = nil

        let tapSec = Double(tapFrameCount) / Double(AudioFormat.sampleRate)
        let sinkSec = Double(sinkFrameCount) / Double(AudioFormat.sampleRate)
        log.notice(
            "capture stopped — tap=\(String(format: "%.1f", tapSec))s"
                + " sink=\(String(format: "%.1f", sinkSec))s"
                + " peakRawRMS=\(String(format: "%.4f", peakRawRMS))"
        )
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard isCapturing, let sink else { return }

        let inputFormat = buffer.format
        let rawRMS = Self.rms(of: buffer)
        peakRawRMS = max(peakRawRMS, rawRMS)

        // Log raw input level on first buffer — diagnoses silence-at-source vs converter issues
        if !firstBufferLogged {
            firstBufferLogged = true
            log.notice(
                "first buffer: format=\(inputFormat.sampleRate)Hz ch=\(inputFormat.channelCount)"
                    + " frames=\(buffer.frameLength) rawRMS=\(String(format: "%.4f", rawRMS))"
            )
        }

        // Periodic signal check every ~5s (80000 frames at 16kHz target ≈ 5s)
        let targetFramesSoFar = tapFrameCount
        if targetFramesSoFar - lastPeriodicLog >= 80_000 {
            lastPeriodicLog = targetFramesSoFar
            log.notice("signal check: rawRMS=\(String(format: "%.4f", rawRMS)) peakRMS=\(String(format: "%.4f", peakRawRMS)) tap=\(tapFrameCount)f")
        }

        tapFrameCount += UInt64(buffer.frameLength)

        // F1: create or recreate converter if format changed (device reconfigured mid-session)
        if converter == nil || inputFormat != lastInputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                log.warning("dropped frame: cannot create converter for \(inputFormat)")
                return
            }
            converter = newConverter
            lastInputFormat = inputFormat
            log.notice(
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

        guard let channel = out.int16ChannelData?[0] else {
            log.warning("dropped frame: converter output has no int16 channel data")
            return
        }
        let frameCount = Int(out.frameLength)
        guard frameCount > 0 else {
            log.warning("dropped frame: converter produced 0 frames")
            return
        }

        sinkFrameCount += UInt64(frameCount)

        let byteCount = frameCount * AudioFormat.bytesPerFrame
        let pcm = Data(bytes: channel, count: byteCount)
        sink(pcm)
    }

    // MARK: - Diagnostics

    private static func actualInputDevice(_ inputNode: AVAudioInputNode) -> String {
        let au = inputNode.audioUnit
        guard let au else { return "no audio unit" }
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr else { return "query failed (OSStatus \(status))" }
        let name = InputDeviceObserver.deviceName(deviceID)
        return "\(name) (\(deviceID))"
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = data[0]
        let count = Int(buffer.frameLength)
        var sumSq: Float = 0
        for i in 0..<count { sumSq += samples[i] * samples[i] }
        return sqrtf(sumSq / Float(count))
    }
}
