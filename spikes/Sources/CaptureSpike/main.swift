import AVFoundation
import Foundation

final class CaptureSpike: NSObject {
    private let engine = AVAudioEngine()
    private var sampleCount = 0
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func run(seconds: Double) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        print("input device format: \(inputFormat.sampleRate) Hz, ch=\(inputFormat.channelCount), \(inputFormat.commonFormat.rawValue)")

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "CaptureSpike", code: 1, userInfo: [NSLocalizedDescriptionKey: "no converter"])
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * self.targetFormat.sampleRate / inputFormat.sampleRate
            ) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: frameCapacity) else { return }
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: out, error: &error, withInputFrom: inputBlock)
            if let error { print("convert error: \(error)"); return }
            if let ch = out.int16ChannelData?[0] {
                self.sampleCount += Int(out.frameLength)
                let peak = (0..<Int(out.frameLength)).map { abs(Int32(ch[$0])) }.max() ?? 0
                if self.sampleCount % 16_000 < Int(out.frameLength) {
                    print("  samples=\(self.sampleCount) peak=\(peak)")
                }
            }
        }

        try engine.start()
        print("engine started — speak into mic for \(seconds)s")
        Thread.sleep(forTimeInterval: seconds)
        input.removeTap(onBus: 0)
        engine.stop()
        print("done: \(sampleCount) samples @ 16kHz (~\(String(format: "%.1f", Double(sampleCount) / 16_000))s)")
    }
}

let secs = Double(CommandLine.arguments.dropFirst().first ?? "3") ?? 3
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
    sem.wait()
default:
    print("microphone not authorized — grant in System Settings → Privacy → Microphone")
    exit(1)
}

let spike = CaptureSpike()
try spike.run(seconds: secs)