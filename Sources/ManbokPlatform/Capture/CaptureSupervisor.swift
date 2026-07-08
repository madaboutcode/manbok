import CoreAudio
import Foundation

// MARK: - CONTRACT: CaptureSupervisor
//
// GUARANTEES:
// - Worker runs iff demand is non-empty — started on the tick demand appears
//   (subject to restart budget), abandoned on the tick demand empties.
// - Every (re)start re-resolves the target: builds [AppDevices] from demand ×
//   processSnapshot() (union of pdv# deviceIDs per bundleID), calls
//   CaptureDevicePolicy.target, creates a FRESH worker via makeWorker.
// - All restarts share CaptureRestartPolicy: mayRestart gates every attempt;
//   recordRestart(wasFlowing:) on every attempt; .error log from 3rd consecutive
//   unhealthy attempt; reset() on clean stop.
// - Byte-flow watchdog at tick time: demand non-empty ∧ capturing ∧
//   isStalled(lastDataAt, captureStartedAt, now) ∧ mayRestart → restart (reason "stall").
// - Target-mismatch check at tick time: freshly resolved target ≠ running target ∧
//   mayRestart → restart (reason "device switch").
// - Digital-silence watchdog: derives silentSince from sink's lock-protected cells,
//   calls silencePolicy.evaluate, executes returned action through SAME restart budget;
//   on .holdEntered logs .error once; calls noteExternalChange() on demand/target changes.
// - Environment signals mailboxed (lock-protected), consumed at next tick:
//   .captureDisturbed → restart via budget; .defaultInputChanged → restart ONLY if
//   target is .systemDefault (D4).
// - Logging (R9): every (re)start logs .notice with device identity + trigger using
//   canonical tokens: arrival, stall, silence, device switch, fallback.
// - apply returns post-decision status: isCapturing, health.
//
// EXPECTS: apply calls serialized; start() before lifecycle.start(); stop() after
//   lifecycle.stop(). processSnapshot cheap/non-destructive; makeWorker returns fresh instance.
//
// FAILURE: worker start throw → logged, isCapturing=false returned, retried on next tick.
//   processSnapshot no devices → policy falls back .systemDefault, logged.
//
// DOES NOT: open/close sessions, publish UI state, parse HAL structures, own a dispatch queue.

public final class CaptureSupervisor: CaptureSupervising {
    // Injected dependencies
    private let makeWorker: () -> PinnedAudioCapturing
    private let processSnapshot: () -> [AudioProcessInfo]
    private let signals: EnvironmentSignaling
    private let appendSink: (Data) -> Void
    private let clock: () -> Date

    // Policies (value types, mutated in apply)
    private var restartPolicy: CaptureRestartPolicy
    private var silencePolicy: SilenceRecoveryPolicy

    // Worker state
    private var worker: PinnedAudioCapturing?
    private var workerTarget: CaptureTarget?
    private var captureStartedAt: Date?

    // Sink-side state (lock-protected — written from worker's delivery thread)
    private let sinkLock = NSLock()
    private var lastDataAt: Date?
    private var silentSince: Date?    // start of continuous peak==0 run; nil if last chunk had signal

    // Signal mailbox (lock-protected — written from signal handler thread)
    private var pendingSignals: [EnvironmentSignal] = []

    // Health / tick bookkeeping
    private var health: CaptureHealth = .idle
    private var isHolding = false
    private var previousDemandBundleIDs: Set<String> = []
    private var previousTarget: CaptureTarget?

    private let log = AppLog(category: .capture)

    public init(
        makeWorker: @escaping () -> PinnedAudioCapturing,
        processSnapshot: @escaping () -> [AudioProcessInfo],
        signals: EnvironmentSignaling,
        appendSink: @escaping (Data) -> Void,
        restartPolicy: CaptureRestartPolicy = .init(),
        silencePolicy: SilenceRecoveryPolicy = .init(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.makeWorker = makeWorker
        self.processSnapshot = processSnapshot
        self.signals = signals
        self.appendSink = appendSink
        self.restartPolicy = restartPolicy
        self.silencePolicy = silencePolicy
        self.clock = clock
    }

    public func start() {
        signals.handler = { [weak self] signal in
            guard let self else { return }
            self.sinkLock.lock()
            self.pendingSignals.append(signal)
            self.sinkLock.unlock()
        }
        signals.activate()
    }

    public func stop() {
        abandonWorker()
        signals.deactivate()
        signals.handler = nil
        restartPolicy.reset()
        silencePolicy.noteExternalChange()
        health = .idle
        isHolding = false
        previousDemandBundleIDs = []
        previousTarget = nil
    }

    public func apply(demand: [DemandEntry], now: Date) -> CaptureStatus {
        guard !demand.isEmpty else {
            abandonWorker()
            restartPolicy.reset()
            silencePolicy.noteExternalChange()
            health = .idle
            isHolding = false
            previousDemandBundleIDs = []
            previousTarget = nil
            return CaptureStatus(isCapturing: false, health: .idle)
        }

        let pendingEnvSignals = drainSignals()
        let target = resolveTarget(demand: demand)
        let demandBundleIDs = Set(demand.map(\.bundleID))
        let externalChange = demandBundleIDs != previousDemandBundleIDs || target != previousTarget

        // restartHappened: a restart executed this tick — gates further checks so we
        // don't stack multiple restarts in one tick. recoveryEvent: a problem was
        // detected this tick (restart executed OR suppressed by backoff) — distinct
        // from a plain "arrival" start, which is healthy, not a recovery. restartWasLadderAction:
        // this tick's restart was a silence-ladder step (noteRestart already advanced
        // the ladder — must not immediately stomp it with noteExternalChange below).
        var restartHappened = false
        var recoveryEvent = false
        var restartWasLadderAction = false

        if worker == nil {
            if restartPolicy.mayRestart(now: now) {
                startWorker(target: target, now: now, trigger: "arrival", wasFlowing: false)
                restartHappened = true
            }
            // else: arrival stays deferred, retried next tick — health resolves to .idle below.
        } else {
            // Target-mismatch check.
            if let workerTarget, workerTarget != target {
                recoveryEvent = true
                if restartPolicy.mayRestart(now: now) {
                    restart(target: target, now: now, trigger: "device switch")
                    restartHappened = true
                }
            }

            // Byte-flow watchdog.
            if !restartHappened, let captureStartedAt {
                sinkLock.lock()
                let lastData = lastDataAt
                sinkLock.unlock()
                if restartPolicy.isStalled(lastDataAt: lastData, captureStartedAt: captureStartedAt, now: now) {
                    recoveryEvent = true
                    if restartPolicy.mayRestart(now: now) {
                        restart(target: target, now: now, trigger: "stall")
                        restartHappened = true
                    }
                }
            }

            // Digital-silence watchdog.
            if !restartHappened, let captureStartedAt {
                sinkLock.lock()
                let currentSilentSince = silentSince
                sinkLock.unlock()
                let action = silencePolicy.evaluate(now: now, silentSince: currentSilentSince, lastWorkerStartAt: captureStartedAt)
                switch action {
                case .none:
                    // Real signal flowing again (silentSince == nil) clears any prior hold.
                    if currentSilentSince == nil { isHolding = false }
                case .reResolveAndRestart:
                    recoveryEvent = true
                    if restartPolicy.mayRestart(now: now) {
                        restart(target: target, now: now, trigger: "silence")
                        silencePolicy.noteRestart(target: target)
                        restartHappened = true
                        restartWasLadderAction = true
                    }
                case .restartInPlace:
                    recoveryEvent = true
                    if restartPolicy.mayRestart(now: now) {
                        let inPlaceTarget = workerTarget ?? target
                        restart(target: inPlaceTarget, now: now, trigger: "silence")
                        silencePolicy.noteRestart(target: inPlaceTarget)
                        restartHappened = true
                        restartWasLadderAction = true
                    }
                case .holdEntered:
                    log.error("capture: silence ladder exhausted — holding")
                    isHolding = true
                }
            }

            // Environment signals (mailboxed above).
            for signal in pendingEnvSignals {
                switch signal {
                case .captureDisturbed(let reason):
                    if restartHappened { continue }
                    recoveryEvent = true
                    if restartPolicy.mayRestart(now: now) {
                        restart(target: target, now: now, trigger: "device switch — \(reason)")
                        restartHappened = true
                    } else {
                        log.notice("signal suppressed (backoff): captureDisturbed(\(reason))")
                    }
                case .defaultInputChanged:
                    guard target == .systemDefault else { continue }
                    if restartHappened { continue }
                    recoveryEvent = true
                    if restartPolicy.mayRestart(now: now) {
                        restart(target: target, now: now, trigger: "device switch — default input changed")
                        restartHappened = true
                    } else {
                        log.notice("signal suppressed (backoff): defaultInputChanged")
                    }
                }
            }
        }

        if externalChange, !restartWasLadderAction {
            silencePolicy.noteExternalChange()
        }

        previousDemandBundleIDs = demandBundleIDs
        previousTarget = target

        if isHolding {
            health = .holdingSilent
        } else if worker == nil {
            health = .idle
        } else if recoveryEvent {
            health = .recovering
        } else {
            health = .capturing
        }

        return CaptureStatus(isCapturing: worker != nil, health: health)
    }

    // MARK: - Target resolution

    private func resolveTarget(demand: [DemandEntry]) -> CaptureTarget {
        let snapshot = processSnapshot()
        var appDevicesMap: [String: (arrivedAt: Date, deviceIDs: Set<AudioDeviceID>)] = [:]
        for entry in demand {
            let procs = snapshot.filter { $0.bundleID == entry.bundleID }
            let devices = procs.flatMap { $0.deviceIDs }
            if var existing = appDevicesMap[entry.bundleID] {
                devices.forEach { existing.deviceIDs.insert($0) }
                existing.arrivedAt = min(existing.arrivedAt, entry.arrivedAt)
                appDevicesMap[entry.bundleID] = existing
            } else {
                appDevicesMap[entry.bundleID] = (arrivedAt: entry.arrivedAt, deviceIDs: Set(devices))
            }
        }
        let appDevices = appDevicesMap.map {
            CaptureDevicePolicy.AppDevices(bundleID: $0.key, arrivedAt: $0.value.arrivedAt, deviceIDs: Array($0.value.deviceIDs))
        }
        return CaptureDevicePolicy.target(demand: appDevices)
    }

    // MARK: - Worker lifecycle

    private func drainSignals() -> [EnvironmentSignal] {
        sinkLock.lock()
        let drained = pendingSignals
        pendingSignals.removeAll()
        sinkLock.unlock()
        return drained
    }

    private func startWorker(target: CaptureTarget, now: Date, trigger: String, wasFlowing: Bool) {
        let newWorker = makeWorker()
        do {
            try newWorker.start(target: target) { [weak self] chunk in
                guard let self else { return }
                self.appendSink(chunk.pcm)
                let stamp = self.clock()
                self.sinkLock.lock()
                self.lastDataAt = stamp
                if chunk.peak == 0 {
                    if self.silentSince == nil { self.silentSince = stamp }
                } else {
                    self.silentSince = nil
                }
                self.sinkLock.unlock()
            }
            worker = newWorker
            workerTarget = target
            captureStartedAt = now
            isHolding = false

            let deviceName = newWorker.boundDevice.map { InputDeviceObserver.deviceName($0) } ?? "unknown"
            let deviceID = newWorker.boundDevice.map { String($0) } ?? "?"
            let triggerToken = target == .systemDefault ? "fallback (\(trigger))" : trigger
            log.notice("capture started — \(triggerToken) → \(deviceName) [\(deviceID)]")

            signals.observe(device: newWorker.boundDevice)

            restartPolicy.recordRestart(now: now, wasFlowing: wasFlowing)

            if restartPolicy.consecutiveUnhealthyRestarts >= 3 {
                log.error("capture: 3+ consecutive unhealthy restarts")
            }
        } catch {
            log.error("worker start failed: \(error)")
            restartPolicy.recordRestart(now: now, wasFlowing: false)
            if restartPolicy.consecutiveUnhealthyRestarts >= 3 {
                log.error("capture: 3+ consecutive unhealthy restarts")
            }
            worker = nil
            workerTarget = nil
            captureStartedAt = nil
        }
    }

    /// Captures byte-flow evidence from the OUTGOING worker before tearing down its
    /// state, so CaptureRestartPolicy can tell a live-engine switch (wasFlowing=true,
    /// backoff resets) from restarting a dead one (wasFlowing=false, backoff grows).
    private func restart(target: CaptureTarget, now: Date, trigger: String) {
        sinkLock.lock()
        let wasFlowing = lastDataAt.map { now.timeIntervalSince($0) < restartPolicy.watchdogThreshold } ?? false
        lastDataAt = nil
        silentSince = nil
        sinkLock.unlock()

        worker?.stop()
        worker = nil
        startWorker(target: target, now: now, trigger: trigger, wasFlowing: wasFlowing)
    }

    private func abandonWorker() {
        worker?.stop()
        worker = nil
        workerTarget = nil
        captureStartedAt = nil
        sinkLock.lock()
        lastDataAt = nil
        silentSince = nil
        pendingSignals.removeAll()
        sinkLock.unlock()
    }
}
