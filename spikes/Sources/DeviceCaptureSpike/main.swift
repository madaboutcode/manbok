import AVFoundation
import CoreAudio
import Foundation

// Spike: opportunistic capture — idle until default input is in use elsewhere, then capture; stop when released.
//
// Run: swift run device-capture-spike [watchSeconds]
// 1. Do NOT run manbok start.
// 2. When prompted, start recording in Voice Memos / Zoom / Meet on the default input.
// 3. When prompted, stop recording in that app.
//
// Pass criteria:
// - runningSomewhere 0→1 while we are idle
// - capture shows non-zero peaks
// - after we stop engine, runningSomewhere returns to 0

// MARK: - Core Audio helpers

private func defaultInputID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    return id
}

private func deviceName(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged) == noErr,
          let cf = unmanaged?.takeRetainedValue() else { return "device \(id)" }
    return cf as String
}

private func isRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return false }
    return value != 0
}

// MARK: - Opportunistic capture

private final class OpportunisticCapture: NSObject {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var isCapturing = false
    private var sampleCount = 0
    private var lastPeak: Int32 = 0
    private let peakLock = NSLock()

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func start() throws {
        guard !isCapturing else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: format, to: targetFormat) else {
            throw SpikeError.converterFailed
        }

        inputFormat = format
        converter = conv
        sampleCount = 0
        isCapturing = true

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }

        try engine.start()
        print("  CAPTURE ON (\(format.sampleRate) Hz → 16 kHz mono)")
    }

    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        inputFormat = nil
        print("  CAPTURE OFF (samples=\(sampleCount), lastPeak=\(lastPeak))")
    }

    var maxPeakSinceStart: Int32 {
        peakLock.lock()
        defer { peakLock.unlock() }
        return lastPeak
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard isCapturing, let converter, let inputFormat else { return }

        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
        ) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        if error != nil { return }

        guard let ch = out.int16ChannelData?[0] else { return }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }

        sampleCount += frames
        let peak = (0..<frames).map { abs(Int32(ch[$0])) }.max() ?? 0
        peakLock.lock()
        lastPeak = max(lastPeak, peak)
        peakLock.unlock()

        if sampleCount % 16_000 < frames {
            print("    pcm samples=\(sampleCount) peak=\(peak)")
        }
    }
}

private enum SpikeError: Error, CustomStringConvertible {
    case noDefaultInput
    case micDenied
    case converterFailed
    case neverWentBusy
    case noPeaks
    case stillBusyAfterRelease

    var description: String {
        switch self {
        case .noDefaultInput: return "no default input device"
        case .micDenied: return "microphone not authorized"
        case .converterFailed: return "AVAudioConverter failed"
        case .neverWentBusy: return "runningSomewhere never became 1 — start recording in another app"
        case .noPeaks: return "capture ran but peak stayed 0"
        case .stillBusyAfterRelease: return "runningSomewhere still 1 after we stopped capture"
        }
    }
}

private func ensureMic() throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            ok = granted
            sem.signal()
        }
        sem.wait()
        guard ok else { throw SpikeError.micDenied }
    default:
        throw SpikeError.micDenied
    }
}

private func waitForBusy(deviceID: AudioDeviceID, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    print("→ waiting for another app to use the mic (runningSomewhere→1), up to \(Int(timeout))s…")
    while Date() < deadline {
        if isRunningSomewhere(deviceID) {
            print("  BUSY detected")
            return
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw SpikeError.neverWentBusy
}

private func waitForIdle(deviceID: AudioDeviceID, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    print("→ waiting for device idle (runningSomewhere→0), up to \(Int(timeout))s…")
    while Date() < deadline {
        if !isRunningSomewhere(deviceID) {
            print("  IDLE detected")
            return
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw SpikeError.stillBusyAfterRelease
}

// MARK: - Main

@main
struct DeviceCaptureSpikeMain {
    static func main() {
        do {
            try run()
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() throws {
try ensureMic()

guard let deviceID = defaultInputID() else { throw SpikeError.noDefaultInput }

let watchSeconds = Double(CommandLine.arguments.dropFirst().first ?? "90") ?? 90
let capture = OpportunisticCapture()

print("device-capture-spike")
print("  default input: \(deviceName(deviceID)) [id=\(deviceID)]")
print("  watch: \(Int(watchSeconds))s total")
print("")
print("INSTRUCTIONS:")
print("  1. When waiting for BUSY — start recording in Voice Memos / Zoom / Meet.")
print("  2. When capturing — keep talking or playing audio for a few seconds.")
print("  3. When told — STOP recording in that other app.")
print("")

var passBusy = false
var passPeaks = false
var passIdle = false

do {
    try waitForBusy(deviceID: deviceID, timeout: min(60, watchSeconds * 0.6))
    passBusy = true

    try capture.start()
    print("→ capture for 8s — use the mic in the other app now…")
    Thread.sleep(forTimeInterval: 8)

    if capture.maxPeakSinceStart > 100 {
        passPeaks = true
        print("  PEAK OK (max=\(capture.maxPeakSinceStart))")
    } else {
        print("  PEAK LOW (max=\(capture.maxPeakSinceStart)) — speak louder or check routing")
    }

    print("")
    print("→ STOP recording in the other app now, then we release our capture…")
    capture.stop()

    Thread.sleep(forTimeInterval: 0.5)
    try waitForIdle(deviceID: deviceID, timeout: 10)
    passIdle = true
} catch {
    capture.stop()
    throw error
}

print("")
print("=== RESULT ===")
print("  0→1 while idle:     \(passBusy ? "PASS" : "FAIL")")
print("  PCM peaks:          \(passPeaks ? "PASS" : "FAIL")")
print("  0 after release:    \(passIdle ? "PASS" : "FAIL")")
if passBusy && passPeaks && passIdle {
    print("  OVERALL: PASS — opportunistic capture is viable")
} else {
    print("  OVERALL: PARTIAL — review lines above")
    exit(passBusy && passIdle ? 0 : 1)
}
    }
}