import Foundation
import ManbokCore

// MARK: - CONTRACT (TerminalCaptureMeter)
//
// GUARANTEES
// - Repaints a fixed meter on the controlling TTY (~15 fps); does not scroll.
// - ActivityPresenting for foregroundMeter presentation only.
//
// DOES NOT
// - Start/stop capture, handle IPC, or configure diagnostics.

/// Live terminal meter (trust + demo).
public final class TerminalCaptureMeter: ActivityPresenting, @unchecked Sendable {
    public enum Mode: Sendable {
        case watching
        case listening
        case capturing(appName: String?)
    }

    private let displayRows = 14
    private let historyWidth = 72
    private let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    private let redrawInterval: TimeInterval = 1.0 / 15.0
    private let quietWarn: TimeInterval = 1.0
    private let quietRelease: TimeInterval = 2.5

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ai.manbok.app.meter", qos: .userInitiated)
    private let painter = TerminalPainter()
    private var peakHistory: [Float] = []
    private var speechHistory: [Bool] = []
    private var maxPeakSeen: Float = 1
    private var lastChunkCount = 0
    private var startedAt = Date()
    private var lastRepaint = Date.distantPast

    private let snapshot: () -> AudioActivitySnapshot
    private let mode: () -> Mode
    private let isCapturing: () -> Bool
    private let ringFilledBytes: () -> Int

    public init(
        snapshot: @escaping () -> AudioActivitySnapshot,
        mode: @escaping () -> Mode,
        isCapturing: @escaping () -> Bool,
        ringFilledBytes: @escaping () -> Int
    ) {
        self.snapshot = snapshot
        self.mode = mode
        self.isCapturing = isCapturing
        self.ringFilledBytes = ringFilledBytes
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            startedAt = Date()
            lastChunkCount = 0
            peakHistory = []
            speechHistory = []
            maxPeakSeen = 1

            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: redrawInterval)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            painter.finish()
        }
    }

    private func tick() {
        let snap = snapshot()
        let m = mode()
        let capturing = isCapturing()

        if snap.chunkCount > lastChunkCount {
            let peakF = Float(snap.peak)
            if peakF > maxPeakSeen { maxPeakSeen = peakF }
            let normalized = maxPeakSeen > 0 ? min(peakF / max(800, maxPeakSeen), 1) : 0
            peakHistory.append(normalized)
            speechHistory.append(snap.isSpeech)
            if peakHistory.count > historyWidth {
                peakHistory.removeFirst()
                speechHistory.removeFirst()
            }
            lastChunkCount = snap.chunkCount
        }

        let now = Date()
        guard now.timeIntervalSince(lastRepaint) >= redrawInterval else { return }
        lastRepaint = now

        let elapsed = now.timeIntervalSince(startedAt)
        let ringBytes = ringFilledBytes()
        painter.write(render(snap: snap, mode: m, capturing: capturing, elapsed: elapsed, ringBytes: ringBytes))
    }

    private func render(
        snap: AudioActivitySnapshot,
        mode: Mode,
        capturing: Bool,
        elapsed: TimeInterval,
        ringBytes: Int
    ) -> String {
        var lines: [String] = []

        let ring = RingBufferSummary(filledBytes: ringBytes)
        switch mode {
        case .watching:
            lines.append(ANSIColor.wrap(ANSIColor.cyan + ANSIColor.bold, "◌ WATCHING  manbok"))
            lines.append(ringStatusLine(ring: ring))
            if ringBytes == 0 {
                lines.append(ANSIColor.wrap(ANSIColor.dim, "  waiting for another app to use the default mic"))
            }
        case .listening:
            lines.append(ANSIColor.wrap(ANSIColor.green + ANSIColor.bold, "● LIVE  manbok  (always-on)"))
            lines.append(statusLine(capturing: capturing, snap: snap, elapsed: elapsed, ring: ring))
        case .capturing(let appName):
            let suffix = appName.map { " · \($0)" } ?? ""
            lines.append(ANSIColor.wrap(ANSIColor.green + ANSIColor.bold, "● LIVE  manbok  (opportunistic\(suffix))"))
            lines.append(statusLine(capturing: capturing, snap: snap, elapsed: elapsed, ring: ring))
        }

        lines.append(ANSIColor.wrap(ANSIColor.dim, String(repeating: "─", count: historyWidth + 4)))

        if capturing {
            lines.append(waveformRow(label: "level ", values: peakHistory, speech: speechHistory))
            lines.append(holdRow(label: "hold ", row: 0))
            lines.append(holdRow(label: "     ", row: 1))
            lines.append(coloredGateRow())
            lines.append(thresholdLegend(snap: snap))
            lines.append("")
            lines.append(levelStats(snap: snap))
            lines.append(activityLine(snap: snap))
        } else if ringBytes > 0 {
            lines.append(ANSIColor.wrap(ANSIColor.dim, "  (capture paused — ring kept; make dump from another tab)"))
        } else {
            lines.append(ANSIColor.wrap(ANSIColor.dim, "  waveform starts when capture begins"))
            lines.append(stateHintRow(mode: .watching))
        }

        lines.append(ANSIColor.wrap(ANSIColor.dim, "  logs → Console (ai.manbok.app) · IPC: status | dump | stop"))

        while lines.count < displayRows {
            lines.append("")
        }
        return lines.prefix(displayRows).joined(separator: "\n")
    }

    private func ringStatusLine(ring: RingBufferSummary) -> String {
        "  " + ANSIColor.wrap(ANSIColor.cyan, ring.displaySuffix)
    }

    private func statusLine(
        capturing: Bool,
        snap: AudioActivitySnapshot,
        elapsed: TimeInterval,
        ring: RingBufferSummary
    ) -> String {
        let ringPart = ANSIColor.wrap(ANSIColor.dim, ring.displaySuffix)
        if capturing {
            return "  \(ANSIColor.wrap(ANSIColor.green, "REC"))  \(String(format: "%.0fs", elapsed))   buffers \(snap.chunkCount)   \(ringPart)"
        }
        return "  uptime \(String(format: "%.0fs", elapsed))   \(ringPart)"
    }

    private func holdRow(label: String, row: Int) -> String {
        var line = label
        line += String(repeating: " ", count: max(0, historyWidth - peakHistory.count))
        for i in 0..<peakHistory.count {
            let v = peakHistory[i]
            let idx = min(blocks.count - 1, max(0, Int(v * Float(blocks.count - 1))))
            let show = idx >= (blocks.count - 1 - row * 2)
            let ch = show ? (speechHistory[i] ? "█" : "░") : " "
            line.append(
                speechHistory[i] && show
                    ? ANSIColor.wrap(ANSIColor.green, ch)
                    : ch
            )
        }
        return line
    }

    private func waveformRow(label: String, values: [Float], speech: [Bool]) -> String {
        var row = label
        row += String(repeating: " ", count: max(0, historyWidth - values.count))
        for i in 0..<values.count {
            let v = values[i]
            let idx = min(blocks.count - 1, max(0, Int(v * Float(blocks.count - 1))))
            let ch = speech[i] ? blocks[idx] : "·"
            row.append(
                speech[i]
                    ? ANSIColor.wrap(ANSIColor.green, String(ch))
                    : ANSIColor.wrap(ANSIColor.gray, String(ch))
            )
        }
        return row
    }

    private func coloredGateRow() -> String {
        var row = "gate  "
        row += String(repeating: " ", count: max(0, historyWidth - speechHistory.count))
        for s in speechHistory {
            row.append(s ? ANSIColor.wrap(ANSIColor.green, "█") : " ")
        }
        return row
    }

    private func thresholdLegend(snap: AudioActivitySnapshot) -> String {
        let band = String(repeating: "▄", count: min(historyWidth, max(peakHistory.count, 8)))
        return "band  " + ANSIColor.wrap(ANSIColor.yellow, band)
            + ANSIColor.wrap(ANSIColor.dim, "  floor \(Int(snap.noiseFloor))  thr \(Int(snap.threshold))")
    }

    private func levelStats(snap: AudioActivitySnapshot) -> String {
        String(format: "  RMS %6.0f   peak %6d   threshold %6.0f",
               snap.rms, snap.peak, snap.threshold)
    }

    private func activityLine(snap: AudioActivitySnapshot) -> String {
        let quiet = snap.secondsSinceSpeech
        let quietStr = quiet.isFinite ? String(format: "%.1f", quiet) : "—"
        if snap.isSpeech {
            return "  " + ANSIColor.wrap(ANSIColor.green + ANSIColor.bold, "SPEECH ●")
                + "   quiet for: \(quietStr)s"
        }
        var line = "  " + ANSIColor.wrap(ANSIColor.dim, "silence ○")
            + "   quiet for: \(quietStr)s"
        if quiet.isFinite, quiet >= quietRelease {
            line += "  " + ANSIColor.wrap(ANSIColor.red, "→ release probe")
        } else if quiet.isFinite, quiet >= quietWarn {
            line += "  " + ANSIColor.wrap(ANSIColor.yellow, "quiet…")
        }
        return line
    }

    private func stateHintRow(mode: Mode) -> String {
        let ch: String
        if case .watching = mode { ch = "w" } else { ch = "." }
        return "state " + String(repeating: ch, count: min(24, historyWidth))
            + ANSIColor.wrap(ANSIColor.dim, "  (w=watching)")
    }
}