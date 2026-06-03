import Foundation
import UpilAppaCore

// MARK: - CONTRACT (OpportunisticCaptureController)
//
// GUARANTEES
// - Does not open AVAudioEngine until default input reports DeviceIsRunningSomewhere while idle.
// - While capturing, stays on until speech-activity quiet, then one release probe checks true idle.
// - Preserves ring buffer across release probes; appends sessionGapSeconds silence on SESSION-END.
//
// EXPECTS
// - ListenerService owns capture + ring; controller only starts/stops capture.
//
// DOES NOT
// - Dump WAV or handle IPC.

/// Polls default input activity and drives ListenerService capture lifecycle.
public final class OpportunisticCaptureController: @unchecked Sendable {
    public enum Phase: Sendable {
        case watching
        case capturing
    }

    private let service: ListenerService
    private let log = AppLog(category: .capture)
    private let queue = DispatchQueue(label: "ai.upil.appa.opportunistic", qos: .userInitiated)

    private let pollInterval: TimeInterval
    /// No speech (VAD-lite) for this long while capturing → run one release probe for true idle.
    private let silenceBeforeRelease: TimeInterval
    private let releaseSettle: TimeInterval

    private var timer: DispatchSourceTimer?
    private var removeDeviceListener: (() -> Void)?
    private var phase: Phase = .watching

    /// Throttled `[trace]` logs for stop-detection debugging (filter Console on `[trace]`).
    private var lastTraceLogAt = Date.distantPast
    private var lastReportedDeviceBusy: Bool?
    private var ringBytesAtLastTrace = 0

    private let traceLogInterval: TimeInterval = 4

    public init(
        service: ListenerService,
        pollInterval: TimeInterval = 0.25,
        silenceBeforeRelease: TimeInterval = 2.5,
        releaseSettle: TimeInterval = 0.35
    ) {
        self.service = service
        self.pollInterval = pollInterval
        self.silenceBeforeRelease = silenceBeforeRelease
        self.releaseSettle = releaseSettle
    }

    public var currentPhase: Phase {
        queue.sync { phase }
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: pollInterval)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source

            removeDeviceListener = InputDeviceObserver.addDefaultInputChangeHandler { [weak self] in
                self?.defaultInputChanged()
            }

            log.info("opportunistic mode: watching for mic activity on default input")
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            removeDeviceListener?()
            removeDeviceListener = nil
            if service.isListening {
                service.stopCapture()
            }
            phase = .watching
        }
    }

    private func tick() {
        if service.isListening {
            let speechQuiet = service.secondsSinceLastSpeech
            let canRelease = Self.shouldReleaseAfterSpeechQuiet(
                secondsSinceLastSpeech: speechQuiet,
                silenceBeforeRelease: silenceBeforeRelease
            )
            if !canRelease {
                traceCapturing(releaseBlocked: true, speechQuiet: speechQuiet)
                return
            }
            trace(
                "release-probe-start speechQuiet=\(fmt(speechQuiet))s " +
                "need=\(fmt(silenceBeforeRelease))s \(captureSignals())"
            )
            releaseProbe()
            return
        }

        phase = .watching
        let deviceBusy = InputDeviceObserver.isDefaultInputBusy()
        traceWatching(deviceBusy: deviceBusy)
        guard deviceBusy else { return }
        trace("watch→capture trigger \(captureSignals())")
        beginCapture()
    }

    private func beginCapture() {
        guard !service.isListening else { return }
        do {
            if let id = InputDeviceObserver.defaultInputDeviceID() {
                log.info("external mic activity — capturing from \(InputDeviceObserver.deviceName(id))")
            }
            try service.startCapture()
            phase = .capturing
            ringBytesAtLastTrace = service.ringFilledBytes
            lastTraceLogAt = Date()
            trace("capture-started \(captureSignals())")
            log.info("capture started — ring \(service.ringFilledBytes) bytes")
        } catch {
            log.error("capture start failed: \(error)")
        }
    }

    /// True only after at least one speech frame, then `silenceBeforeRelease` without speech.
    static func shouldReleaseAfterSpeechQuiet(
        secondsSinceLastSpeech: TimeInterval,
        silenceBeforeRelease: TimeInterval
    ) -> Bool {
        guard secondsSinceLastSpeech.isFinite else { return false }
        return secondsSinceLastSpeech >= silenceBeforeRelease
    }

    /// Stop engine briefly to see if IO is still active (after speech went quiet).
    private func releaseProbe() {
        let ringBefore = service.ringFilledBytes
        let deviceBusyBeforeSettle = InputDeviceObserver.isDefaultInputBusy()
        trace(
            "release-probe engine-stop ringBefore=\(ringBefore) " +
            "deviceBusy=\(deviceBusyBeforeSettle ? 1 : 0)"
        )

        service.stopCapture()
        Thread.sleep(forTimeInterval: releaseSettle)

        let deviceBusy = InputDeviceObserver.isDefaultInputBusy()
        let ringAfter = service.ringFilledBytes
        let ringDelta = ringAfter - ringBefore

        if deviceBusy {
            do {
                try service.startCapture()
                phase = .capturing
                trace(
                    "release-probe RESUME deviceBusy=1 ringAfter=\(ringAfter) " +
                    "ringDeltaWhileStopped=\(ringDelta) \(captureSignals()) " +
                    "hypothesis=H2-external-still-busy-or-stale-flag"
                )
            } catch {
                log.error("capture resume failed: \(error)")
                phase = .watching
                trace("release-probe RESUME-FAILED \(captureSignals())")
            }
        } else {
            phase = .watching
            if ringAfter > 0 {
                service.insertSessionGap()
            }
            let ringWithGap = service.ringFilledBytes
            trace(
                "release-probe SESSION-END deviceBusy=0 ringAfter=\(ringAfter) " +
                "ringWithGap=\(ringWithGap) gap=\(AudioFormat.sessionGapSeconds)s " +
                "ringDeltaWhileStopped=\(ringDelta) hypothesis=ok-stop"
            )
            log.info(
                "mic idle — stopped capture (ring \(ringWithGap) bytes, " +
                "+\(AudioFormat.sessionGapSeconds)s session gap)"
            )
            ringBytesAtLastTrace = ringWithGap
        }
        lastReportedDeviceBusy = deviceBusy
        if deviceBusy {
            ringBytesAtLastTrace = ringAfter
        }
        lastTraceLogAt = Date()
    }

    private func defaultInputChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let id = InputDeviceObserver.defaultInputDeviceID() else { return }
            self.log.info("default input changed → \(InputDeviceObserver.deviceName(id))")
            self.trace(
                "default-input-changed listening=\(self.service.isListening ? 1 : 0) " +
                "runningSomewhere=\(InputDeviceObserver.isRunningSomewhere(id) ? 1 : 0)"
            )
            if self.service.isListening {
                self.service.stopCapture()
            }
            self.phase = .watching
            if InputDeviceObserver.isRunningSomewhere(id) {
                self.beginCapture()
            }
        }
    }

    // MARK: - Stop-detection trace (hypothesis elimination)

    /// H1: VAD never quiet → release-blocked logs, speechQuiet stays low / isSpeech=1
    /// H2: probe runs but deviceBusy=1 → RESUME logs
    /// H3: device never idle while capturing → deviceBusy=1 on every heartbeat
    /// H4: ring grows while watching → watching heartbeat ringDelta>0
    /// H5: ring grows after engine stop → ringDeltaWhileStopped>0

    private func traceCapturing(releaseBlocked: Bool, speechQuiet: TimeInterval) {
        phase = .capturing
        guard shouldEmitTrace() else { return }
        let ring = service.ringFilledBytes
        let ringDelta = ring - ringBytesAtLastTrace
        let hypothesis = releaseBlocked
            ? (speechQuiet.isFinite ? "H1-vad-not-quiet" : "H1-no-speech-yet")
            : "capturing"
        trace(
            "capturing releaseBlocked=\(releaseBlocked ? 1 : 0) " +
            "speechQuiet=\(fmt(speechQuiet))s need=\(fmt(silenceBeforeRelease))s " +
            "ring=\(ring) ringDelta=\(ringDelta) \(captureSignals()) hypothesis=\(hypothesis)"
        )
        ringBytesAtLastTrace = ring
        lastTraceLogAt = Date()
    }

    private func traceWatching(deviceBusy: Bool) {
        if lastReportedDeviceBusy != deviceBusy {
            trace("watching deviceBusy \(lastReportedDeviceBusy.map { $0 ? "1" : "0" } ?? "?")→\(deviceBusy ? 1 : 0) ring=\(service.ringFilledBytes)")
            lastReportedDeviceBusy = deviceBusy
        }
        guard shouldEmitTrace() else { return }
        let ring = service.ringFilledBytes
        let ringDelta = ring - ringBytesAtLastTrace
        if ringDelta != 0 {
            trace(
                "watching ringGROWTH=\(ringDelta) ring=\(ring) deviceBusy=\(deviceBusy ? 1 : 0) " +
                "hypothesis=H4-ring-growing-while-not-capturing"
            )
        } else {
            trace("watching idle ring=\(ring) deviceBusy=\(deviceBusy ? 1 : 0)")
        }
        ringBytesAtLastTrace = ring
        lastTraceLogAt = Date()
    }

    private func captureSignals() -> String {
        let snap = service.currentActivity
        let speechQuiet = service.secondsSinceLastSpeech
        let audioQuiet = service.secondsSinceLastAudio
        let deviceBusy = InputDeviceObserver.isDefaultInputBusy()
        return [
            "phase=\(phase)",
            "listening=\(service.isListening ? 1 : 0)",
            "deviceBusy=\(deviceBusy ? 1 : 0)",
            "speechQuiet=\(fmt(speechQuiet))s",
            "audioQuiet=\(fmt(audioQuiet))s",
            "rms=\(Int(snap.rms))",
            "isSpeech=\(snap.isSpeech ? 1 : 0)",
            "chunks=\(snap.chunkCount)",
        ].joined(separator: " ")
    }

    private func shouldEmitTrace() -> Bool {
        Date().timeIntervalSince(lastTraceLogAt) >= traceLogInterval
    }

    private func trace(_ message: String) {
        log.info("[trace] \(message)")
    }

    private func fmt(_ t: TimeInterval) -> String {
        t.isFinite ? String(format: "%.1f", t) : "inf"
    }
}