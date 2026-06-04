import Foundation
import UpilAppaCore

// MARK: - CONTRACT (OpportunisticCaptureController)
//
// GUARANTEES
// - Does not open AVAudioEngine until ProcessAudioMonitor detects another app using input.
// - While capturing, engine stays on until all other apps release input, then drains for gracePeriod.
// - Draining keeps engine running — zero audio loss at session end.
// - Appends sessionGapSeconds silence on SESSION-END; tags session with app name(s).
//
// EXPECTS
// - ListenerService owns capture + ring; controller only starts/stops capture.
// - macOS 14+ (ProcessAudioMonitor requires Sonoma ProcessObjectList APIs).
//
// DOES NOT
// - Dump WAV or handle IPC.
// - Use VAD for session lifecycle (VAD remains in ListenerService for visualization only).

public final class OpportunisticCaptureController: @unchecked Sendable {
    public enum Phase: Sendable, Equatable {
        case watching
        case capturing
        case draining
    }

    private let service: ListenerService
    private let monitor: ProcessAudioMonitor
    private let log = AppLog(category: .capture)
    private let queue = DispatchQueue(label: "ai.upil.appa.opportunistic", qos: .userInitiated)

    private let watchingPollInterval: TimeInterval
    private let capturingPollInterval: TimeInterval
    private let drainingPollInterval: TimeInterval
    private let gracePeriod: TimeInterval

    private var timer: DispatchSourceTimer?
    private var removeDeviceListener: (() -> Void)?
    private var phase: Phase = .watching

    private var activeAppBundleIDs: Set<String> = []
    private var drainStartedAt: Date?
    private var captureRetryAfter: Date?

    private var lastTraceLogAt = Date.distantPast
    private var ringBytesAtLastTrace = 0
    private let traceLogInterval: TimeInterval = 4

    public init(
        service: ListenerService,
        monitor: ProcessAudioMonitor = ProcessAudioMonitor(),
        watchingPollInterval: TimeInterval = 0.5,
        capturingPollInterval: TimeInterval = 2.0,
        drainingPollInterval: TimeInterval = 1.0,
        gracePeriod: TimeInterval = 5.0
    ) {
        self.service = service
        self.monitor = monitor
        self.watchingPollInterval = watchingPollInterval
        self.capturingPollInterval = capturingPollInterval
        self.drainingPollInterval = drainingPollInterval
        self.gracePeriod = gracePeriod
    }

    public var currentPhase: Phase {
        queue.sync { phase }
    }

    public var currentAppName: String? {
        queue.sync { ProcessAudioMonitor.appName(for: activeAppBundleIDs) }
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            scheduleTimer(interval: watchingPollInterval)

            removeDeviceListener = InputDeviceObserver.addDefaultInputChangeHandler { [weak self] in
                self?.defaultInputChanged()
            }

            log.info("opportunistic mode: watching for mic activity via ProcessAudioMonitor")
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
            activeAppBundleIDs = []
            drainStartedAt = nil
        }
    }

    // MARK: - Tick

    private func tick() {
        switch phase {
        case .watching:
            tickWatching()
        case .capturing:
            tickCapturing()
        case .draining:
            tickDraining()
        }
    }

    private func tickWatching() {
        // Back off if a recent capture attempt failed (device still settling).
        if let retryAfter = captureRetryAfter, Date() < retryAfter { return }

        let inputProcs = monitor.otherInputProcesses()
        guard !inputProcs.isEmpty else {
            traceWatching(inputCount: 0)
            return
        }
        let bundleIDs = Set(inputProcs.map(\.bundleID))
        trace("watch→capture \(bundleIDs.joined(separator: ", "))")
        beginCapture(bundleIDs: bundleIDs)
    }

    private func tickCapturing() {
        let inputProcs = monitor.otherInputProcesses()
        if inputProcs.isEmpty {
            drainStartedAt = Date()
            phase = .draining
            scheduleTimer(interval: drainingPollInterval)
            trace("capture→draining apps released, grace=\(fmt(gracePeriod))s \(signals())")
            log.info("all apps released mic — draining for \(Int(gracePeriod))s before session end")
            return
        }
        let newBundleIDs = Set(inputProcs.map(\.bundleID))
        let added = newBundleIDs.subtracting(activeAppBundleIDs)
        if !added.isEmpty {
            activeAppBundleIDs.formUnion(added)
            let appName = ProcessAudioMonitor.appName(for: activeAppBundleIDs) ?? "unknown"
            service.setSessionAppName(appName)
            trace("new app(s) joined: \(added.joined(separator: ", ")) total=\(activeAppBundleIDs)")
        }
        traceCapturing()
    }

    private func tickDraining() {
        let inputProcs = monitor.otherInputProcesses()
        if !inputProcs.isEmpty {
            let newBundleIDs = Set(inputProcs.map(\.bundleID))
            activeAppBundleIDs.formUnion(newBundleIDs)
            let appName = ProcessAudioMonitor.appName(for: activeAppBundleIDs) ?? "unknown"
            service.setSessionAppName(appName)
            drainStartedAt = nil
            phase = .capturing
            scheduleTimer(interval: capturingPollInterval)
            trace("draining→capture app reclaimed: \(newBundleIDs.joined(separator: ", ")) \(signals())")
            log.info("app reclaimed mic — continuing capture")
            return
        }

        guard let drainStart = drainStartedAt else {
            drainStartedAt = Date()
            return
        }
        let elapsed = Date().timeIntervalSince(drainStart)
        if elapsed >= gracePeriod {
            endSession()
        } else {
            traceDraining(elapsed: elapsed)
        }
    }

    // MARK: - Session lifecycle

    private func beginCapture(bundleIDs: Set<String>) {
        guard !service.isListening else { return }
        activeAppBundleIDs = bundleIDs
        let appName = ProcessAudioMonitor.appName(for: bundleIDs) ?? "unknown"
        do {
            try service.startCapture()
            captureRetryAfter = nil
            service.setSessionAppName(appName)
            phase = .capturing
            scheduleTimer(interval: capturingPollInterval)
            ringBytesAtLastTrace = service.ringFilledBytes
            lastTraceLogAt = Date()
            trace("capture-started app=\(appName) \(signals())")
            log.info("capture started — \(appName)")
        } catch {
            captureRetryAfter = Date().addingTimeInterval(1.0)
            log.error("capture start failed (retry in 1s): \(error)")
        }
    }

    private func endSession() {
        let appName = ProcessAudioMonitor.appName(for: activeAppBundleIDs)
        service.stopCapture()
        if service.ringFilledBytes > 0 {
            service.insertSessionGap(appName: appName)
        }
        let ringBytes = service.ringFilledBytes
        trace("SESSION-END app=\(appName ?? "?") ring=\(ringBytes) \(signals())")
        log.info("session ended — \(appName ?? "unknown") (ring \(ringBytes) bytes)")

        phase = .watching
        activeAppBundleIDs = []
        drainStartedAt = nil
        ringBytesAtLastTrace = ringBytes
        scheduleTimer(interval: watchingPollInterval)
    }

    // MARK: - Device change

    private func defaultInputChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let id = InputDeviceObserver.defaultInputDeviceID() else { return }
            self.log.info("default input changed → \(InputDeviceObserver.deviceName(id))")
            if self.service.isListening {
                self.service.stopCapture()
            }
            self.phase = .watching
            self.activeAppBundleIDs = []
            self.drainStartedAt = nil
            self.scheduleTimer(interval: self.watchingPollInterval)

            let inputProcs = self.monitor.otherInputProcesses()
            if !inputProcs.isEmpty {
                let bundleIDs = Set(inputProcs.map(\.bundleID))
                self.beginCapture(bundleIDs: bundleIDs)
            }
        }
    }

    // MARK: - Timer management

    private func scheduleTimer(interval: TimeInterval) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    // MARK: - Trace logging

    private func traceWatching(inputCount: Int) {
        guard shouldEmitTrace() else { return }
        trace("watching idle inputProcs=\(inputCount) ring=\(service.ringFilledBytes)")
        lastTraceLogAt = Date()
    }

    private func traceCapturing() {
        guard shouldEmitTrace() else { return }
        let ring = service.ringFilledBytes
        let delta = ring - ringBytesAtLastTrace
        trace("capturing ring=\(ring) delta=\(delta) apps=\(activeAppBundleIDs.count) \(signals())")
        ringBytesAtLastTrace = ring
        lastTraceLogAt = Date()
    }

    private func traceDraining(elapsed: TimeInterval) {
        guard shouldEmitTrace() else { return }
        trace("draining elapsed=\(fmt(elapsed))s grace=\(fmt(gracePeriod))s ring=\(service.ringFilledBytes)")
        lastTraceLogAt = Date()
    }

    private func signals() -> String {
        let snap = service.currentActivity
        return [
            "phase=\(phase)",
            "listening=\(service.isListening ? 1 : 0)",
            "rms=\(Int(snap.rms))",
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
