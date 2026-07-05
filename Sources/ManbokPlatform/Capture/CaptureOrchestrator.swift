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
// - Both @Published properties are updated on the main thread.
//
// EXPECTS:
// - AudioCapturing, SessionRegistry, ProcessAudioMonitor, AppIdentityResolver injected.
// - start()/stop() are idempotent and safe to call from any thread.
//
// FAILURE BEHAVIOR:
// - capture.start throws -> retry after 1s (same backoff as OpportunisticCaptureController);
//   sessions are not opened for an arrival until capture is actually running.
//
// DOES NOT:
// - Own the ring or session storage (SessionRegistry does).
// - Route IPC or touch UI.
// - Run VAD (stays in ListenerService, used only for the foreground meter).
// - Observe default-input device changes (InputDeviceObserver) — can be layered on later.

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
public final class CaptureOrchestrator: ObservableObject {
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
    private var captureRetryAfter: Date?
    private var lastPermissionCheck: Date?
    private let permissionCheckInterval: TimeInterval = 30.0

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
        gracePeriod: TimeInterval = 5.0
    ) {
        self.capture = capture
        self.registry = registry
        self.monitor = monitor
        self.resolver = resolver
        self.pollInterval = pollInterval
        self.gracePeriod = gracePeriod
    }

    public func start() {
        queue.sync {
            guard pollTimer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: pollInterval)
            source.setEventHandler { [weak self] in self?.poll() }
            source.resume()
            pollTimer = source
            log.notice("orchestrator started — polling every \(pollInterval)s")
        }
    }

    public func stop() {
        queue.sync {
            pollTimer?.cancel()
            pollTimer = nil
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
            captureRetryAfter = nil
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
        if let retryAfter = captureRetryAfter, Date() < retryAfter { return }
        do {
            try capture.start { [weak self] data in
                self?.registry.append(data)
            }
            isCapturing = true
            captureRetryAfter = nil
            log.notice("capture started")
        } catch {
            captureRetryAfter = Date().addingTimeInterval(1.0)
            log.error("capture start failed (retry in 1s): \(error)")
        }
    }

    private func stopCaptureIfIdle() {
        guard isCapturing else { return }
        guard !registry.anySessionOpen, drainTimers.isEmpty else { return }
        capture.stop()
        isCapturing = false
        log.notice("capture stopped — all sessions closed")
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
