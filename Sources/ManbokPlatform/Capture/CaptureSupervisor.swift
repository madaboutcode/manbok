import CoreAudio
import Foundation

// MARK: - CONTRACT: CaptureSupervisor
//
// GUARANTEES:
// - Worker runs iff demand is non-empty AND some demand entry lists a candidate device —
//   started on the tick that holds (subject to restart budget), abandoned on the tick either
//   condition ends. There is no gap hold: no candidate device releases the worker.
// - Every tick re-resolves the target from DemandEntry.deviceIDs (the demand reducer already
//   applied the holder/draining/live-device rule; no HAL read here), via
//   CaptureDevicePolicy.resolve (passing workerTarget as currentTarget for its tie-break);
//   every (re)start creates a FRESH worker via makeWorker.
// - Releasing the worker for "no candidate device" remembers whether bytes were flowing
//   by keeping lastDataAt (abandon for empty demand and stop() clear it). The next arrival start
//   computes wasFlowing from it exactly as restart() does (lastDataAt within watchdogThreshold),
//   consumes it, so a healthy mic switch does not grow the restart backoff.
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
//   .captureDisturbed → restart via budget; .defaultInputChanged is inert (device-following
//   via pdv# handles all switches; system default is irrelevant).
// - Logging (R9): every (re)start logs .notice with device identity + trigger using
//   canonical tokens: arrival, stall, silence, device switch; a start that replaces a different
//   device names the old one ("from ..."). Every worker stop outside restart() (no demand, no
//   candidate device, supervisor stop) logs one "capture stopped — reason" .notice. A "device switch" caused
//   by CaptureDevicePolicy's tie-break carries which branch fired ("tie: newest
//   relationship" / "tie: lowest-id fallback"); a plain (non-tied) switch does not.
// - apply returns post-decision status: isCapturing, health.
//
// EXPECTS: apply calls serialized; start() before lifecycle.start(); stop() after
//   lifecycle.stop(). makeWorker returns fresh instance.
//
// FAILURE: worker start throw → logged, isCapturing=false returned, retried on next tick.
//   No candidate device → target nil: running worker released (logged .notice), no worker
//   started, health is .deferredNoDevice (logged .notice).
//
// DOES NOT: open/close sessions, publish UI state, parse HAL structures, own a dispatch queue.

public final class CaptureSupervisor: CaptureSupervising {
    // Injected dependencies
    private let makeWorker: () -> PinnedAudioCapturing
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
        signals: EnvironmentSignaling,
        appendSink: @escaping (Data) -> Void,
        restartPolicy: CaptureRestartPolicy = .init(),
        silencePolicy: SilenceRecoveryPolicy = .init(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.makeWorker = makeWorker
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
        abandonWorker(reason: "supervisor stopped")
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
            abandonWorker(reason: "no demand")
            restartPolicy.reset()
            silencePolicy.noteExternalChange()
            health = .idle
            isHolding = false
            previousDemandBundleIDs = []
            previousTarget = nil
            return CaptureStatus(isCapturing: false, health: .idle)
        }

        let pendingEnvSignals = drainSignals()
        let (target, tieBreak) = resolveTarget(demand: demand)
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

        if let target {
            if worker == nil {
                if restartPolicy.mayRestart(now: now) {
                    // lastDataAt survives only a release for "no candidate device"; otherwise nil.
                    let wasFlowing = bytesFlowing(now: now)
                    sinkLock.lock(); lastDataAt = nil; sinkLock.unlock()
                    startWorker(target: target, now: now, trigger: "arrival", wasFlowing: wasFlowing)
                    restartHappened = true
                }
                // else: arrival stays deferred, retried next tick — health resolves to .idle below.
            } else {
                // Target-mismatch check.
                if let workerTarget, workerTarget != target {
                    recoveryEvent = true
                    if restartPolicy.mayRestart(now: now) {
                        let trigger: String
                        switch tieBreak {
                        case .newestRelationship: trigger = "device switch — tie: newest relationship"
                        case .lowestIDFallback: trigger = "device switch — tie: lowest-id fallback"
                        case .noTie: trigger = "device switch"
                        }
                        restart(target: target, now: now, trigger: trigger)
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
                        continue  // device-following via pdv# handles all switches; system default is irrelevant
                    }
                }
            }
        } else {
            // target == nil: demand present but no candidate device. Release the worker (no gap hold);
            // log only on state entry to avoid spam.
            if worker != nil {
                let from = workerTarget.map(Self.describe) ?? "?"
                releaseWorkerKeepingFlowEvidence()
                log.notice("capture stopped — no candidate device (was \(from))")
            } else if previousTarget != nil || previousDemandBundleIDs.isEmpty {
                log.notice("demand present but no device visible — deferring capture")
            }
        }

        if externalChange, !restartWasLadderAction {
            silencePolicy.noteExternalChange()
        }

        previousDemandBundleIDs = demandBundleIDs
        previousTarget = target

        if target == nil, worker == nil {
            health = .deferredNoDevice
        } else if isHolding {
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

    private func resolveTarget(demand: [DemandEntry]) -> (target: CaptureTarget?, tieBreak: CaptureDevicePolicy.TieBreakBranch) {
        let appDevices = demand.map {
            CaptureDevicePolicy.AppDevices(bundleID: $0.bundleID, arrivedAt: $0.arrivedAt, deviceIDs: $0.deviceIDs.sorted())
        }
        return CaptureDevicePolicy.resolve(demand: appDevices, currentTarget: workerTarget)
    }

    // MARK: - Worker lifecycle

    private func drainSignals() -> [EnvironmentSignal] {
        sinkLock.lock()
        let drained = pendingSignals
        pendingSignals.removeAll()
        sinkLock.unlock()
        return drained
    }

    private static func describe(_ target: CaptureTarget) -> String {
        switch target {
        case .systemDefault: return "system default"
        case .device(let id): return "\(InputDeviceObserver.deviceName(id)) [\(id)]"
        }
    }

    private func startWorker(target: CaptureTarget, now: Date, trigger: String, wasFlowing: Bool) {
        let previousTarget = workerTarget
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
            let switchedFrom = previousTarget.flatMap { $0 != target ? " (from \(Self.describe($0)))" : nil } ?? ""
            log.notice("capture started — \(trigger) → \(deviceName) [\(deviceID)]\(switchedFrom)")

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
        let wasFlowing = bytesFlowing(now: now)
        sinkLock.lock()
        lastDataAt = nil
        silentSince = nil
        sinkLock.unlock()

        worker?.stop()
        worker = nil
        startWorker(target: target, now: now, trigger: trigger, wasFlowing: wasFlowing)
    }

    private func bytesFlowing(now: Date) -> Bool {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        return lastDataAt.map { now.timeIntervalSince($0) < restartPolicy.watchdogThreshold } ?? false
    }

    private func releaseWorkerKeepingFlowEvidence() {
        worker?.stop()
        worker = nil
        workerTarget = nil
        captureStartedAt = nil
        sinkLock.lock()
        silentSince = nil
        pendingSignals.removeAll()
        sinkLock.unlock()
    }

    private func abandonWorker(reason: String) {
        if worker != nil { log.notice("capture stopped — \(reason)") }
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
