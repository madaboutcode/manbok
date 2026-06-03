import Foundation
import UpilAppaCore

// MARK: - CONTRACT (OpportunisticCaptureController)
//
// GUARANTEES
// - Does not open AVAudioEngine until default input reports DeviceIsRunningSomewhere while idle.
// - While capturing, periodically releases engine and re-checks busy (spike-validated pattern).
// - Preserves ring buffer across release probes.
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
    private let probeInterval: TimeInterval
    private let releaseSettle: TimeInterval

    private var timer: DispatchSourceTimer?
    private var removeDeviceListener: (() -> Void)?
    private var phase: Phase = .watching
    private var lastProbe = Date.distantPast

    public init(
        service: ListenerService,
        pollInterval: TimeInterval = 0.25,
        probeInterval: TimeInterval = 1.5,
        releaseSettle: TimeInterval = 0.35
    ) {
        self.service = service
        self.pollInterval = pollInterval
        self.probeInterval = probeInterval
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
            guard Date().timeIntervalSince(lastProbe) >= probeInterval else { return }
            lastProbe = Date()
            releaseProbe()
            return
        }

        phase = .watching
        guard InputDeviceObserver.isDefaultInputBusy() else { return }
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
            lastProbe = Date()
        } catch {
            log.error("capture start failed: \(error)")
        }
    }

    /// Stop engine briefly to see if IO is still active (we pollute runningSomewhere while capturing).
    private func releaseProbe() {
        service.stopCapture()
        Thread.sleep(forTimeInterval: releaseSettle)

        if InputDeviceObserver.isDefaultInputBusy() {
            do {
                try service.startCapture()
                phase = .capturing
            } catch {
                log.error("capture resume failed: \(error)")
                phase = .watching
            }
        } else {
            phase = .watching
            log.info("mic idle — stopped capture (ring preserved)")
        }
    }

    private func defaultInputChanged() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let id = InputDeviceObserver.defaultInputDeviceID() else { return }
            self.log.info("default input changed → \(InputDeviceObserver.deviceName(id))")
            if self.service.isListening {
                self.service.stopCapture()
            }
            self.phase = .watching
            if InputDeviceObserver.isRunningSomewhere(id) {
                self.beginCapture()
            }
        }
    }
}