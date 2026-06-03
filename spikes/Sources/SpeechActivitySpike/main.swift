import AVFoundation
import Darwin
import Foundation

// Spike: LIVE mic → immediate AVAudioEngine tap → waveform repaints in place.
// Does NOT wait for Zoom/Voice Memos (that's device-capture-spike).
//
// Run: swift run speech-activity-spike          # until Ctrl+C
//      swift run speech-activity-spike 60      # fixed seconds

private let displayRows = 11
private let historyWidth = 72
private let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
private let redrawInterval: TimeInterval = 1.0 / 15.0

private var stdoutIsTTY: Bool {
    isatty(STDOUT_FILENO) == 1
}

/// Repaint fixed rows on stdout (no alternate screen — works with swift run + IDE terminals).
private final class TerminalPainter {
    private var paintedOnce = false

    init() {
        setlinebuf(stdout)
    }

    func write(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard stdoutIsTTY else {
            // Piped / non-TTY: compact status (cursor control does not work).
            for line in lines where line.contains("recording") || line.contains("RMS") {
                fputs("\(line)\n", stdout)
            }
            fflush(stdout)
            return
        }
        if !paintedOnce {
            fputs(lines.joined(separator: "\n") + "\n", stdout)
            paintedOnce = true
        } else {
            fputs("\u{001B}[\(lines.count)F", stdout)
            for line in lines {
                fputs("\u{001B}[2K\(line)\n", stdout)
            }
        }
        fflush(stdout)
    }

    func finish() {
        guard stdoutIsTTY, paintedOnce else { return }
        fputs("\n", stdout)
        fflush(stdout)
    }
}

final class TerminalCanvas {
    private var peakHistory: [Float] = []
    private var speechHistory: [Bool] = []

    func push(peak: Float, speech: Bool, maxPeak: Float) {
        let normalized = maxPeak > 0 ? min(peak / maxPeak, 1) : 0
        peakHistory.append(normalized)
        speechHistory.append(speech)
        if peakHistory.count > historyWidth {
            peakHistory.removeFirst()
            speechHistory.removeFirst()
        }
    }

    func render(
        metrics: SpeechActivityDetector.FrameMetrics,
        floor: Float,
        secondsSinceSpeech: TimeInterval,
        elapsed: TimeInterval,
        chunks: Int
    ) -> String {
        var lines: [String] = []
        lines.append("● LIVE mic  speech-activity-spike  (waveform updates as captured)")
        lines.append(String(format: "  recording %.0fs   buffers %d   (no other app required)", elapsed, chunks))
        lines.append(String(repeating: "─", count: historyWidth + 4))
        lines.append(waveformRow(label: "level ", values: peakHistory, speech: speechHistory))
        lines.append(speechGateRow())
        lines.append(thresholdRow())
        lines.append("")
        lines.append(String(format: "  RMS %6.0f   peak %6d   threshold %6.0f   floor %6.0f",
                            metrics.rms, metrics.peak, metrics.threshold, floor))
        let activity = metrics.isSpeech ? "SPEECH ●" : "silence ○"
        lines.append("  activity: \(activity)   quiet for: \(String(format: "%.1f", secondsSinceSpeech))s")
        lines.append("  mic open — Ctrl+C to quit")
        while lines.count < displayRows {
            lines.append("")
        }
        return lines.prefix(displayRows).joined(separator: "\n")
    }

    private func waveformRow(label: String, values: [Float], speech: [Bool]) -> String {
        var row = label
        row += String(repeating: " ", count: max(0, historyWidth - values.count))
        for i in 0..<values.count {
            let v = values[i]
            let idx = min(blocks.count - 1, max(0, Int(v * Float(blocks.count - 1))))
            row.append(speech[i] ? blocks[idx] : "·")
        }
        return row
    }

    private func speechGateRow() -> String {
        var row = "gate  "
        row += String(repeating: " ", count: max(0, historyWidth - speechHistory.count))
        for s in speechHistory {
            row.append(s ? "█" : " ")
        }
        return row
    }

    private func thresholdRow() -> String {
        var row = "thr  "
        row += String(repeating: " ", count: max(0, historyWidth - peakHistory.count))
        row += String(repeating: "─", count: peakHistory.count)
        return row
    }
}

private var stopLiveCapture = false

final class LiveCapture: NSObject {
    private let engine = AVAudioEngine()
    private var detector = SpeechActivityDetector()
    private let canvas = TerminalCanvas()
    private let painter = TerminalPainter()
    private var lastSpeechAt = Date()
    private var startedAt = Date()
    private(set) var chunkCount = 0
    private var maxPeakSeen: Float = 1
    private var lastMetrics = SpeechActivityDetector.FrameMetrics(rms: 0, peak: 0, threshold: 0, isSpeech: false)
    private var lastRepaint = Date.distantPast
    private let paintLock = NSLock()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func run(seconds: TimeInterval) throws {
        fputs("Opening microphone…\n", stdout)
        fflush(stdout)
        try ensureMic()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        fputs(String(format: "Input: %.0f Hz  %d ch\n", inputFormat.sampleRate, inputFormat.channelCount), stdout)
        fflush(stdout)

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio converter"])
        }

        stopLiveCapture = false
        signal(SIGINT) { _ in stopLiveCapture = true }

        defer { painter.finish() }

        startedAt = Date()
        chunkCount = 0
        // Match capture-spike: tap with strong self, no prepare() — weak self dropped callbacks here.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [self] buffer, _ in
            ingest(buffer: buffer, inputFormat: inputFormat, converter: converter)
        }
        try engine.start()
        fputs("Recording — waveform below updates live.\n\n", stdout)
        fflush(stdout)
        repaintIfDue(force: true)

        let limit = seconds > 0 ? seconds : .infinity
        let end = Date().addingTimeInterval(limit)
        while !stopLiveCapture && Date() < end {
            Thread.sleep(forTimeInterval: 0.05)
            repaintIfDue(force: false)
        }
        input.removeTap(onBus: 0)
        engine.stop()
    }

    /// Called on the audio thread — no terminal I/O here.
    private func ingest(
        buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) {
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
        guard error == nil, let ch = out.int16ChannelData?[0] else { return }
        let frames = Int(out.frameLength)
        guard frames > 0 else { return }

        let byteCount = frames * 2
        let pcm = Data(bytes: ch, count: byteCount)
        var det = detector
        let m = det.analyze(pcm: pcm)
        detector = det

        paintLock.lock()
        chunkCount += 1
        if m.isSpeech { lastSpeechAt = Date() }
        lastMetrics = m
        let peakF = Float(m.peak)
        if peakF > maxPeakSeen { maxPeakSeen = peakF }
        canvas.push(peak: peakF, speech: m.isSpeech, maxPeak: max(800, maxPeakSeen))
        paintLock.unlock()
    }

    private func repaintIfDue(force: Bool) {
        let now = Date()
        paintLock.lock()
        let due = force || now.timeIntervalSince(lastRepaint) >= redrawInterval
        if !due {
            paintLock.unlock()
            return
        }
        lastRepaint = now
        let quiet = now.timeIntervalSince(lastSpeechAt)
        let elapsed = now.timeIntervalSince(startedAt)
        let chunks = chunkCount
        let frame = canvas.render(
            metrics: lastMetrics,
            floor: detector.noiseFloor,
            secondsSinceSpeech: quiet,
            elapsed: elapsed,
            chunks: chunks
        )
        paintLock.unlock()
        painter.write(frame)
    }

    private func ensureMic() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            fputs("Allow microphone when macOS prompts…\n", stdout)
            fflush(stdout)
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            AVCaptureDevice.requestAccess(for: .audio) { ok = $0; sem.signal() }
            sem.wait()
            guard ok else {
                throw NSError(domain: "spike", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "microphone denied — System Settings → Privacy → Microphone"])
            }
        default:
            throw NSError(domain: "spike", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "microphone not authorized — System Settings → Privacy → Microphone"])
        }
    }
}

do {
    let arg = CommandLine.arguments.dropFirst().first
    let secs: Double
    if let arg, let n = Double(arg) {
        secs = n
    } else {
        secs = 0
    }
    let live = LiveCapture()
    try live.run(seconds: secs)
    fputs("Done. (\(live.chunkCount) audio buffers)\n", stdout)
    fflush(stdout)
} catch {
    fputs("Error: \(error.localizedDescription)\n", stdout)
    exit(1)
}