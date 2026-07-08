import AVFoundation
import Foundation
import XCTest
@testable import ManbokCore
@testable import ManbokPlatform

/// End-to-end capture loopback test: plays a known tone ladder through the speakers and
/// captures it with the REAL production path — AUHALWorker → SessionRegistry.append (the
/// exact wiring CaptureSupervisor uses: `appendSink: { reg.append($0) }` in ManbokApp.swift)
/// → WavPCMEncoder + WavFileWriter (the same encoder ExportService's dump path uses).
///
/// This proves the shipped capture pipeline records the right audio, cleanly — specifically
/// that AVAudioConverter chunk boundaries don't splice/drop samples (the regression this
/// test exists to catch).
///
/// Requires: real speaker output + real mic input, quiet room, MANBOK_E2E=1.
/// Run: make test-e2e
final class CaptureE2ETests: XCTestCase {

    private func skipUnlessRequested() throws {
        guard ProcessInfo.processInfo.environment["MANBOK_E2E"] == "1" else {
            throw XCTSkip("e2e loopback test — set MANBOK_E2E=1 to run (needs real speaker+mic, see `make test-e2e`)")
        }
    }

    // MARK: - Probe tone ladder

    private static let toneFrequencies: [Double] = [400, 600, 800, 1000, 1200]
    private static let toneDuration: Double = 1.0
    private static let silenceLeadOut: Double = 0.5
    private static let probeSampleRate: Double = 48_000
    private static let fadeSeconds: Double = 0.010
    private static let amplitude: Float = 0.35

    // MARK: - Test

    func test_captureRecordsCleanToneLadder() throws {
        try skipUnlessRequested()

        let probeURL = try Self.writeProbeWAV()

        let worker = AUHALWorker()
        let registry = SessionRegistry()
        let bundleID = "ai.manbok.e2e-probe"

        let stableId = registry.openSession(bundleID: bundleID, displayName: "E2E Probe")

        // Mirrors ManbokApp.swift's CaptureSupervisor wiring: appendSink: { reg.append($0) }.
        try worker.start(target: .systemDefault) { chunk in
            registry.append(chunk.pcm)
        }
        defer { worker.stop() }

        XCTAssertNotNil(worker.boundDevice, "boundDevice should be set after start")

        // Let the engine settle before playback so we don't clip the first tone.
        Thread.sleep(forTimeInterval: 0.3)

        let afplay = Process()
        afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        afplay.arguments = [probeURL.path]
        try afplay.run()
        afplay.waitUntilExit()

        Thread.sleep(forTimeInterval: 0.5)

        worker.stop()
        registry.closeSession(bundleID: bundleID)

        guard let pcm = registry.snapshotForSession(stableId: stableId) else {
            XCTFail("captured session expired or missing from registry — ring too small for probe duration?")
            return
        }
        XCTAssertFalse(pcm.isEmpty, "captured PCM should not be empty")

        // Real encode + write path — same as ExportService.writeSessionWAV.
        let wav = WavPCMEncoder.encode(pcm: pcm)
        let dumpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manbok-e2e-\(Int(Date().timeIntervalSince1970)).wav")
        try WavFileWriter.write(wavData: wav, to: dumpURL)

        let samples = Self.s16Samples(from: pcm)
        let windowSize = 1600 // 100ms @ 16kHz
        let windows = Self.analyzeWindows(samples: samples, sampleRate: AudioFormat.sampleRate, windowSize: windowSize)

        // (b) SIGNAL PRESENT — fail loudly and actionably rather than pass silently.
        guard windows.contains(where: { $0.label != nil }) else {
            XCTFail("no probe tones detected — check output volume is audible, input device is the built-in mic, and the room is quiet")
            return
        }

        let runs = Self.detectToneRuns(
            windows: windows, windowSize: windowSize, sampleRate: AudioFormat.sampleRate, minDuration: 0.7
        )

        // (a) IDENTITY + ORDER — exactly one qualifying run per tone, in ladder order.
        XCTAssertEqual(
            runs.map(\.label), Array(0..<Self.toneFrequencies.count),
            "expected tones in ladder order \(Self.toneFrequencies); detected \(runs.map { Self.toneFrequencies[$0.label] })"
        )

        print("=== E2E capture verification ===")
        print("captured WAV: \(dumpURL.path)")
        for run in runs {
            let freq = Self.toneFrequencies[run.label]
            let duration = Double(run.endSample - run.startSample) / Double(AudioFormat.sampleRate)
            print(String(format: "  tone %.0f Hz: %.2fs (samples %d..<%d)", freq, duration, run.startSample, run.endSample))
        }

        guard let first = runs.first, let last = runs.last else {
            // (a)'s XCTAssertEqual already failed above; nothing further to measure.
            return
        }

        // (d) DURATION sanity.
        let totalSpanSeconds = Double(last.endSample - first.startSample) / Double(AudioFormat.sampleRate)
        XCTAssertTrue(
            (4.5...6.0).contains(totalSpanSeconds),
            "detected tone span \(totalSpanSeconds)s outside expected 4.5-6.0s"
        )
        print(String(format: "  total tone span: %.2fs", totalSpanSeconds))

        // (c) CONTINUITY — the regression this test exists for.
        var boundaryDeltas: [Double] = []
        var innerDeltas: [Double] = []
        for i in (first.startSample + 1)..<last.endSample {
            let delta = abs(Double(samples[i]) - Double(samples[i - 1]))
            if i % 320 == 0 {
                boundaryDeltas.append(delta)
            } else {
                innerDeltas.append(delta)
            }
        }
        let meanBoundary = boundaryDeltas.isEmpty ? 0 : boundaryDeltas.reduce(0, +) / Double(boundaryDeltas.count)
        let meanInner = innerDeltas.isEmpty ? 0 : innerDeltas.reduce(0, +) / Double(innerDeltas.count)
        let boundaryRatio = meanInner > 0 ? meanBoundary / meanInner : 0
        XCTAssertLessThan(
            boundaryRatio, 1.5,
            "boundary/inner |Δ| ratio \(boundaryRatio) — suggests splice discontinuities at 320-sample block boundaries"
        )

        var totalClicks = 0
        for run in runs {
            guard run.endSample > run.startSample + 1 else { continue }
            var deltas: [Double] = []
            deltas.reserveCapacity(run.endSample - run.startSample - 1)
            for i in (run.startSample + 1)..<run.endSample {
                deltas.append(abs(Double(samples[i]) - Double(samples[i - 1])))
            }
            let p95 = Self.percentile(deltas, 0.95)
            let threshold = 8 * p95
            totalClicks += deltas.filter { $0 > threshold }.count
        }
        XCTAssertLessThan(
            totalClicks, 5,
            "detected \(totalClicks) splice clicks across tone segments (threshold: 8x p95 |Δ| per segment)"
        )

        print(String(format: "  boundary/inner delta ratio: %.3f", boundaryRatio))
        print("  splice clicks: \(totalClicks)")

        // (c cont'd) BROADBAND HF-BURST DETECTION — clicks are broadband; pure tones carry
        // near-zero energy at 3.5-8kHz, so a burst of high-band energy inside a tone run is a
        // clean discriminator even for clicks too small to clear the delta-percentile threshold
        // above (that check catches violent splices; this one catches quieter periodic clicks).
        let bursts = Self.detectClickBursts(samples: samples, runs: runs, sampleRate: AudioFormat.sampleRate)
        XCTAssertEqual(
            bursts.count, 0,
            "\(bursts.count) broadband click bursts detected inside tones — capture path is inserting clicks (HF energy +12 dB over tonal baseline)"
        )
        if let worst = bursts.max(by: { $0.highBandEnergy / $0.baseline < $1.highBandEnergy / $1.baseline }) {
            let worstTime = Double(worst.windowStartSample) / Double(AudioFormat.sampleRate)
            print(String(
                format: "  click bursts: %d (worst at %.3fs, %.1fx baseline)",
                bursts.count, worstTime, worst.highBandEnergy / worst.baseline
            ))
        } else {
            print("  click bursts: 0")
        }

        // Human proof: let the runner hear what was actually recorded.
        let playback = Process()
        playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        playback.arguments = [dumpURL.path]
        try? playback.run()
        playback.waitUntilExit()
    }

    // MARK: - Probe WAV generation

    private static func writeProbeWAV() throws -> URL {
        let sampleRate = probeSampleRate
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw NSError(domain: "CaptureE2ETests", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to build probe AVAudioFormat"])
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manbok-e2e-probe-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        func writeSegment(_ samples: [Float]) throws {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw NSError(domain: "CaptureE2ETests", code: 2, userInfo: [NSLocalizedDescriptionKey: "failed to allocate probe buffer"])
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            let channelData = buffer.floatChannelData![0]
            for i in 0..<samples.count { channelData[i] = samples[i] }
            try file.write(from: buffer)
        }

        let silence = [Float](repeating: 0, count: Int(silenceLeadOut * sampleRate))
        try writeSegment(silence)

        for freq in toneFrequencies {
            let n = Int(toneDuration * sampleRate)
            let fadeSamples = Int(fadeSeconds * sampleRate)
            var segment = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Double(i) / sampleRate
                var s = Float(sin(2 * Double.pi * freq * t)) * amplitude
                if i < fadeSamples {
                    s *= Float(i) / Float(fadeSamples)
                } else if i >= n - fadeSamples {
                    s *= Float(n - i) / Float(fadeSamples)
                }
                segment[i] = s
            }
            try writeSegment(segment)
        }

        try writeSegment(silence)

        return url
    }

    // MARK: - PCM decode

    private static func s16Samples(from data: Data) -> [Int16] {
        let byteCount = data.count - (data.count % 2)
        var samples = [Int16]()
        samples.reserveCapacity(byteCount / 2)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i < byteCount {
                let lo = UInt16(raw[i])
                let hi = UInt16(raw[i + 1])
                samples.append(Int16(bitPattern: lo | (hi << 8)))
                i += 2
            }
        }
        return samples
    }

    // MARK: - Tone detection

    private struct AnalysisWindow {
        let startSample: Int
        let label: Int? // index into toneFrequencies, nil if no tone dominates
    }

    private struct ToneRun {
        let label: Int
        let startSample: Int
        let endSample: Int // exclusive
    }

    private struct ClickBurst {
        let windowStartSample: Int
        let highBandEnergy: Double
        let baseline: Double
    }

    /// 3.5-8kHz Goertzel bank — clicks are broadband, pure tones (400-1200Hz) are not, so a
    /// spike here inside a tone run is a clean click discriminator.
    private static let highBandFrequencies: [Double] = [3600, 4400, 5200, 6000, 6800, 7600]

    /// Scans each tone run in 20ms/10ms-hop windows for high-band energy spikes far above that
    /// run's own median (excludes the first/last 3 windows — tone fade edges cause legitimate
    /// small bursts). +12dB (15.8x power) over baseline flags a window as a click burst.
    private static func detectClickBursts(samples: [Int16], runs: [ToneRun], sampleRate: Int) -> [ClickBurst] {
        let windowSize = 320 // 20ms @ 16kHz
        let hop = 160 // 10ms
        let burstMultiplier = 15.8 // +12dB in power

        var bursts: [ClickBurst] = []
        for run in runs {
            var windowEnergies: [(start: Int, energy: Double)] = []
            var start = run.startSample
            while start + windowSize <= run.endSample {
                let slice = samples[start..<(start + windowSize)].map { Double($0) }
                let energy = highBandFrequencies.reduce(0.0) {
                    $0 + goertzelPower(samples: slice, sampleRate: Double(sampleRate), targetFreq: $1)
                }
                windowEnergies.append((start, energy))
                start += hop
            }
            guard windowEnergies.count > 6 else { continue } // too short to trim 3 windows off each edge

            let interior = windowEnergies.dropFirst(3).dropLast(3)
            guard !interior.isEmpty else { continue }
            let baseline = median(interior.map(\.energy))
            guard baseline > 0 else { continue }
            let threshold = baseline * burstMultiplier

            for window in interior where window.energy > threshold {
                bursts.append(ClickBurst(windowStartSample: window.start, highBandEnergy: window.energy, baseline: baseline))
            }
        }
        return bursts
    }

    /// Goertzel power (squared magnitude) at `targetFreq` over `samples`.
    private static func goertzelPower(samples: [Double], sampleRate: Double, targetFreq: Double) -> Double {
        let n = samples.count
        let k = Int(0.5 + Double(n) * targetFreq / sampleRate)
        let omega = 2.0 * Double.pi * Double(k) / Double(n)
        let cosine = cos(omega)
        let coeff = 2.0 * cosine
        var q0 = 0.0, q1 = 0.0, q2 = 0.0
        for sample in samples {
            q0 = coeff * q1 - q2 + sample
            q2 = q1
            q1 = q0
        }
        let real = q1 - q2 * cosine
        let imag = q2 * sin(omega)
        return real * real + imag * imag
    }

    /// Classifies each 50%-overlapping window as one of the 5 probe tones, or unclassified.
    /// Silent-window baseline is derived data-driven (bottom quartile of window energy) rather
    /// than from assumed playback timing, since capture start/stop has variable latency.
    private static func analyzeWindows(samples: [Int16], sampleRate: Int, windowSize: Int) -> [AnalysisWindow] {
        let hop = windowSize / 2
        guard samples.count >= windowSize else { return [] }

        var rawPowers: [[Double]] = []
        var totalEnergy: [Double] = []
        var starts: [Int] = []

        var start = 0
        while start + windowSize <= samples.count {
            let slice = samples[start..<(start + windowSize)].map { Double($0) }
            let powers = toneFrequencies.map { goertzelPower(samples: slice, sampleRate: Double(sampleRate), targetFreq: $0) }
            rawPowers.append(powers)
            totalEnergy.append(slice.reduce(0.0) { $0 + $1 * $1 })
            starts.append(start)
            start += hop
        }
        guard !rawPowers.isEmpty else { return [] }

        let sortedEnergy = totalEnergy.sorted()
        let silentCutoffIndex = max(0, min(sortedEnergy.count - 1, Int(Double(sortedEnergy.count) * 0.25)))
        let silentThreshold = sortedEnergy[silentCutoffIndex]

        let silentPowers = totalEnergy.indices
            .filter { totalEnergy[$0] <= silentThreshold }
            .map { rawPowers[$0].max() ?? 0 }
        let medianSilentPower = median(silentPowers.isEmpty ? [1.0] : silentPowers)
        let medianSilentDb = 10 * log10(max(medianSilentPower, 1e-6))

        return rawPowers.indices.map { i in
            let dbs = rawPowers[i].map { 10 * log10(max($0, 1e-6)) }
            let ranked = dbs.enumerated().sorted { $0.element > $1.element }
            let topIdx = ranked[0].offset
            let topDb = ranked[0].element
            let secondDb = ranked[1].element
            let qualifies = (topDb - secondDb >= 6) && (topDb - medianSilentDb >= 10)
            return AnalysisWindow(startSample: starts[i], label: qualifies ? topIdx : nil)
        }
    }

    /// Groups consecutive same-label windows into runs, keeping only runs spanning >= minDuration.
    private static func detectToneRuns(
        windows: [AnalysisWindow], windowSize: Int, sampleRate: Int, minDuration: Double
    ) -> [ToneRun] {
        var runs: [ToneRun] = []
        var i = 0
        while i < windows.count {
            guard let label = windows[i].label else { i += 1; continue }
            var j = i
            while j + 1 < windows.count, windows[j + 1].label == label {
                j += 1
            }
            let startSample = windows[i].startSample
            let endSample = windows[j].startSample + windowSize
            let duration = Double(endSample - startSample) / Double(sampleRate)
            if duration >= minDuration {
                runs.append(ToneRun(label: label, startSample: startSample, endSample: endSample))
            }
            i = j + 1
        }
        return runs
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) - 1) * p)))
        return sorted[idx]
    }
}
