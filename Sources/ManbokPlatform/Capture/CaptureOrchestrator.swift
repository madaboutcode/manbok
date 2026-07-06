import AVFoundation
import Combine
import Foundation
import ManbokCore

// MARK: - CONTRACT: CaptureOrchestrator
//
// GUARANTEES:
// - Per-app start/stop derived from set-diff of consecutive polls (currentBundleIDs vs
//   previousBundleIDs), not from the old union-identity model.
// - App appears -> registry.openSession(bundleID:, displayName:) using AppIdentityResolver.
// - App disappears -> starts a per-app drain timer; timer expires -> registry.closeSession
//   (bundleID:); app reclaimed before expiry -> timer is cancelled, no session churn.
// - Publishes anySessionOpen: Bool. Stays true through drain (one-signal rule) — true when
//   registry.anySessionOpen OR any drain timer is active.
// - Publishes micPermission: MicPermissionState, refreshed at poll cadence from
//   AVCaptureDevice.authorizationStatus(for: .audio).
// - Engine starts on first arrival (registry empty and no timers); stops once every session
//   is closed and no drain timers remain.
// - Capture self-heals while sessions are open: restarts on default-input change, on
//   AVAudioEngineConfigurationChange, and on byte-flow stall (watchdog on the poll tick —
//   engine.isRunning is untrustworthy, byte flow is ground truth). Sessions stay OPEN
//   across restarts; the ring just gets a short gap.
// - Restarts are rate-limited with exponential backoff (CaptureRestartPolicy): a device
//   that can't hold capture converges to one attempt per 30s — never a flap loop, never
//   a strobing mic indicator. Repeated unhealthy restarts escalate to .error logs.
// - Logs input-device identity (name + id) at notice level on every capture (re)start.
// - Both @Published properties are updated on the main thread.
//
// EXPECTS:
// - AudioCapturing, SessionRegistry, ProcessAudioMonitor, AppIdentityResolver injected.
// - start()/stop() are idempotent and safe to call from any thread.
//
// FAILURE BEHAVIOR:
// - capture.start throws -> retried on subsequent polls at the policy's backoff;
//   sessions are not opened for an arrival until capture is actually running.
// - Device-change signals arriving inside the backoff window are suppressed; the
//   watchdog is the backstop (spike-proven: a debounce alone can swallow the terminal
//   stop event — see tasks/decisions-20260706-device-change-robustness.md).
//
// DOES NOT:
// - Own the ring or session storage (SessionRegistry does).
// - Route IPC or touch UI.
// - Run VAD (stays in ListenerService, used only for the foreground meter).
// - Pin capture to a specific (non-default) device — capture follows the system default
//   input; per-app device following is queued (tasks/next-follow-app-mic.md).

public enum MicPermissionState: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined

    static func from(_ status: AVAuthorizationStatus) -> MicPermissionState {
        switch status {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

/// Per-app capture lifecycle: set-diff polling drives SessionRegistry open/close directly.
///
/// @unchecked Sendable: all mutable state is confined to `queue` (poll/session/capture
/// state), protected by `dataClock` (lastDataAtStorage, written from the audio thread),
/// or written only on the main queue (@Published, via the shadow-copy publish pattern).
public final class CaptureOrchestrator: ObservableObject, @unchecked Sendable {
    private let capture: AudioCapturing
    private let registry: SessionRegistry
    private let monitor: ProcessAudioMonitor
    private let resolver: AppIdentityResolver
    private let log = AppLog(category: .capture)
    private let queue = DispatchQueue(label: "ai.manbok.app.orchestrator", qos: .userInitiated)

    private let pollInterval: TimeInterval
    private let gracePeriod: TimeInterval

    private var pollTimer: DispatchSourceTimer?
    private var drainTimers: [String: DispatchSourceTimer] = [:]
    private var previousBundleIDs: Set<String> = []
    private var knownPIDs: [String: pid_t] = [:]
    private var isCapturing = false
    private var lastPermissionCheck: Date?
    private let permissionCheckInterval: TimeInterval = 30.0

    // Self-healing capture (mutated only on `queue`, except lastDataAt — see dataClock).
    private var restartPolicy: CaptureRestartPolicy
    private var captureStartedAt: Date?
    private var removeDeviceListener: (() -> Void)?
    private var configChangeObserver: NSObjectProtocol?

    // Written from the audio tap thread, read on `queue` by the watchdog.
    private let dataClock = NSLock()
    private var lastDataAtStorage: Date?
    private var lastDataAt: Date? {
        dataClock.lock()
        defer { dataClock.unlock() }
        return lastDataAtStorage
    }

    // Shadow copies, mutated only on `queue`, so publish() never reads the @Published
    // properties (those are written on the main queue) from a background thread.
    private var anySessionOpenLocal = false
    private var micPermissionLocal = MicPermissionState.notDetermined

    @Published public private(set) var anySessionOpen: Bool = false
    @Published public private(set) var micPermission: MicPermissionState = .notDetermined

    public init(
        capture: AudioCapturing,
        registry: SessionRegistry,
        monitor: ProcessAudioMonitor = ProcessAudioMonitor(),
        resolver: AppIdentityResolver = .shared,
        pollInterval: TimeInterval = 2.0,
        gracePeriod: TimeInterval = 5.0,
        restartPolicy: CaptureRestartPolicy = CaptureRestartPolicy()
    ) {
        self.capture = capture
        self.registry = registry
        self.monitor = monitor
        self.resolver = resolver
        self.pollInterval = pollInterval
        self.gracePeriod = gracePeriod
        self.restartPolicy = restartPolicy
    }

    public func start() {
        queue.sync {
            guard pollTimer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: pollInterval)
            source.setEventHandler { [weak self] in self?.poll() }
            source.resume()
            pollTimer = source

            // Device-change signals. Both funnel into the same rate-limited restart path;
            // the poll-tick watchdog is the backstop for anything these miss or suppress.
            removeDeviceListener = InputDeviceObserver.addDefaultInputChangeHandler { [weak self] in
                self?.queue.async { [weak self] in
                    self?.deviceEnvironmentChanged(reason: "default input changed")
                }
            }
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil, // capture engine is recreated per (re)start; ours is the only engine in-process
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.deviceEnvironmentChanged(reason: "engine configuration changed")
                }
            }

            log.notice("orchestrator started — polling every \(pollInterval)s")
        }
    }

    public func stop() {
        queue.sync {
            pollTimer?.cancel()
            pollTimer = nil
            removeDeviceListener?()
            removeDeviceListener = nil
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            for (_, timer) in drainTimers { timer.cancel() }
            drainTimers.removeAll()
            if isCapturing {
                capture.stop()
                isCapturing = false
            }
            for bundleID in previousBundleIDs {
                registry.closeSession(bundleID: bundleID)
            }
            previousBundleIDs.removeAll()
            knownPIDs.removeAll()
            resetCaptureHealth()
            publish(anySessionOpen: false)
        }
    }

    // MARK: - Poll tick

    private func poll() {
        let now = Date()
        if lastPermissionCheck == nil || now.timeIntervalSince(lastPermissionCheck!) >= permissionCheckInterval {
            lastPermissionCheck = now
            publish(micPermission: MicPermissionState.from(AVCaptureDevice.authorizationStatus(for: .audio)))
        }

        let processes = monitor.otherInputProcesses()
        for proc in processes { knownPIDs[proc.bundleID] = proc.pid }
        let currentBundleIDs = Set(processes.map(\.bundleID))

        let arrived = currentBundleIDs.subtracting(previousBundleIDs)
        let departed = previousBundleIDs.subtracting(currentBundleIDs)

        if !arrived.isEmpty {
            handleArrived(arrived)
        }
        if !departed.isEmpty {
            handleDeparted(departed)
        }

        previousBundleIDs = currentBundleIDs

        // Self-healing: while sessions should be recording, capture must be alive AND
        // producing bytes. Recovers from failed starts (nothing else retries once
        // arrivals stop changing) and from silent engine death (isRunning lies; byte
        // flow is ground truth).
        let shouldCapture = registry.anySessionOpen || !drainTimers.isEmpty
        if shouldCapture {
            if !isCapturing {
                startCapture()
            } else if let startedAt = captureStartedAt,
                      restartPolicy.isStalled(lastDataAt: lastDataAt, captureStartedAt: startedAt, now: now),
                      restartPolicy.mayRestart(now: now) {
                restartCapture(reason: "watchdog: no audio ≥\(Int(restartPolicy.watchdogThreshold))s")
            }
        }

        publish(anySessionOpen: registry.anySessionOpen || !drainTimers.isEmpty)
    }

    private func handleArrived(_ bundleIDs: Set<String>) {
        if !isCapturing {
            startCapture()
            guard isCapturing else { return } // start failed; arrivals retried next tick
        }
        for bundleID in bundleIDs {
            drainTimers[bundleID]?.cancel()
            drainTimers[bundleID] = nil
            let pid = knownPIDs[bundleID] ?? 0
            let displayName = resolver.resolve(bundleID: bundleID, pid: pid)
            registry.openSession(bundleID: bundleID, displayName: displayName)
            log.notice("session opened — \(displayName) (\(bundleID))")
        }
    }

    private func handleDeparted(_ bundleIDs: Set<String>) {
        for bundleID in bundleIDs {
            guard drainTimers[bundleID] == nil else { continue }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + gracePeriod)
            source.setEventHandler { [weak self] in self?.expireDrain(bundleID: bundleID) }
            source.resume()
            drainTimers[bundleID] = source
            log.info("drain started — \(bundleID) grace=\(gracePeriod)s")
        }
    }

    private func expireDrain(bundleID: String) {
        drainTimers[bundleID]?.cancel()
        drainTimers[bundleID] = nil
        registry.closeSession(bundleID: bundleID)
        knownPIDs.removeValue(forKey: bundleID)
        log.notice("session closed — \(bundleID)")
        stopCaptureIfIdle()
        publish(anySessionOpen: registry.anySessionOpen || !drainTimers.isEmpty)
    }

    // MARK: - Capture engine lifecycle

    private func startCapture() {
        guard !isCapturing else { return }
        let now = Date()
        guard restartPolicy.mayRestart(now: now) else { return } // retried next poll tick
        let wasFlowing = lastDataAt.map {
            now.timeIntervalSince($0) < restartPolicy.watchdogThreshold
        } ?? false
        restartPolicy.recordRestart(now: now, wasFlowing: wasFlowing)
        if restartPolicy.consecutiveUnhealthyRestarts >= 3 {
            log.error(
                "capture unhealthy — attempt #\(restartPolicy.consecutiveUnhealthyRestarts + 1),"
                    + " backing off to \(Int(restartPolicy.currentDelay))s"
            )
        }
        do {
            try capture.start { [weak self] data in
                guard let self else { return }
                self.registry.append(data)
                self.dataClock.lock()
                self.lastDataAtStorage = Date()
                self.dataClock.unlock()
            }
            isCapturing = true
            captureStartedAt = now
            log.notice("capture started — input=\(currentInputDescription())")
        } catch {
            log.error("capture start failed (retry in \(Int(restartPolicy.currentDelay))s): \(error)")
        }
    }

    private func restartCapture(reason: String) {
        guard isCapturing else { return }
        log.notice("capture restarting (\(reason)) — input=\(currentInputDescription())")
        capture.stop()
        isCapturing = false
        startCapture()
    }

    private func deviceEnvironmentChanged(reason: String) {
        guard isCapturing else { return } // idle: next arrival starts a fresh engine anyway
        let now = Date()
        guard restartPolicy.mayRestart(now: now) else {
            // Suppressed signals are safe: the watchdog catches a dead engine next tick.
            log.info("restart suppressed (\(reason)) — within backoff window")
            return
        }
        restartCapture(reason: reason)
    }

    private func stopCaptureIfIdle() {
        guard isCapturing else { return }
        guard !registry.anySessionOpen, drainTimers.isEmpty else { return }
        capture.stop()
        isCapturing = false
        resetCaptureHealth()
        log.notice("capture stopped — all sessions closed")
    }

    private func resetCaptureHealth() {
        restartPolicy.reset()
        captureStartedAt = nil
        dataClock.lock()
        lastDataAtStorage = nil
        dataClock.unlock()
    }

    private func currentInputDescription() -> String {
        guard let id = InputDeviceObserver.defaultInputDeviceID() else { return "unknown" }
        return "\(InputDeviceObserver.deviceName(id)) (\(id))"
    }

    // MARK: - Published state

    private func publish(anySessionOpen value: Bool) {
        guard anySessionOpenLocal != value else { return }
        anySessionOpenLocal = value
        DispatchQueue.main.async { [weak self] in self?.anySessionOpen = value }
    }

    private func publish(micPermission value: MicPermissionState) {
        guard micPermissionLocal != value else { return }
        micPermissionLocal = value
        DispatchQueue.main.async { [weak self] in self?.micPermission = value }
    }
}
