import AVFoundation
import Combine
import Foundation
import ManbokCore

// MARK: - CONTRACT: SessionLifecycleController
//
// PURPOSE: The stable half — owns poll timer, session lifecycle (set-diff, drain,
// registry open/close), and published UI state. Talks to capture supervision ONLY
// through the CaptureSupervising waist protocol.
//
// GUARANTEES:
// - Owns the poll timer (~2s) on its serial queue. Each tick: snapshot → set-diff
//   against last tick's raw presence → build demand → supervisor.apply(demand:now:) →
//   process arrivals/departures.
// - Demand = one DemandEntry per current bundleID; arrivedAt per §11.1: first tick
//   of session-continuous presence, preserved across drain reclaim, reset only when
//   drain expires (session closes).
// - Arrival → cancel pending drain, registry.openSession (idempotent if already open);
//   arrivals deferred while !status.isCapturing (left unseen so next tick retries —
//   the retry re-establishes a fresh arrivedAt, since nothing was persisted for it).
// - Departure → per-app drain timer (gracePeriod), started exactly once per departure
//   (idempotent: a still-absent app is not re-detected as "departed" on later ticks
//   because the diff is against last tick's raw presence, not a persistent map).
//   Expiry → registry.closeSession, arrivedAt reset. Reclaim before expiry cancels the
//   timer, no session churn, arrivedAt preserved.
// - anySessionOpen = registry.anySessionOpen || !drainTimers.isEmpty (one-signal rule).
// - micPermission refreshed via permission() at 30s cadence.
// - stop(): cancel timers, final supervisor.apply(demand: [], now:), close every
//   session that is open or draining, publish anySessionOpen=false. Composition root
//   then calls supervisor.stop().
//
// EXPECTS:
// - start/stop idempotent, any thread. Supervisor synchronous per §11.1.
//
// FAILURE:
// - None of its own; capture failures reach it ONLY as isCapturing=false (arrivals defer).
//
// DOES NOT: touch devices, workers, watchdogs, restart or silence policy — its only
// capture knowledge is the waist. Enforced by the §11.1 source-scan test.

/// Per-app session lifecycle: set-diff polling drives demand into the capture waist and
/// SessionRegistry open/close directly. The volatile half (workers, devices, watchdogs,
/// recovery) is entirely behind `CaptureSupervising` — this type never sees it.
///
/// @unchecked Sendable: all mutable state is confined to `queue`, except the @Published
/// properties, which are written only on the main queue (shadow-copy publish pattern).
public final class SessionLifecycleController: ObservableObject, @unchecked Sendable {
    // Dependencies (injected)
    private let supervisor: CaptureSupervising
    private let registry: SessionRegistry
    private let processSnapshot: () -> [AudioProcessInfo]
    private let resolver: AppIdentityResolver
    private let permission: () -> MicPermissionState
    private let pollInterval: TimeInterval
    private let gracePeriod: TimeInterval

    private let log = AppLog(category: .capture)
    private let queue = DispatchQueue(label: "ai.manbok.app.lifecycle", qos: .userInitiated)

    private var pollTimer: DispatchSourceTimer?
    private var permissionTimer: DispatchSourceTimer?
    private var isRunning = false

    // Raw presence from the last tick's snapshot — NOT a persistent "known apps" map.
    // Diffing against this (rather than against every bundleID we've ever seen) is what
    // keeps departure detection idempotent: once an app drops out, it stays out of this
    // set, so a still-absent app is never re-reported as "departed" on later ticks.
    private var previousBundleIDs: Set<String> = []
    private var knownPIDs: [String: pid_t] = [:]

    // Persisted across drain: cleared only when a session actually closes (drain expiry),
    // so a depart-and-reclaim within grace preserves the original arrival tick (§11.1 C2/C3).
    private var arrivedAtByBundleID: [String: Date] = [:]

    private var drainTimers: [String: DispatchSourceTimer] = [:]

    // Shadow copies — publish() is called from `queue`, so it must not read the
    // @Published properties themselves (those are written on the main queue).
    private var anySessionOpenLocal = false
    private var micPermissionLocal = MicPermissionState.notDetermined

    @Published public private(set) var anySessionOpen: Bool = false
    @Published public private(set) var micPermission: MicPermissionState = .notDetermined

    public init(
        supervisor: CaptureSupervising,
        registry: SessionRegistry,
        processSnapshot: @escaping () -> [AudioProcessInfo],
        resolver: AppIdentityResolver = .shared,
        // Inlined rather than calling MicPermissionState.from(_:): that static method is
        // `internal` (owned by CaptureOrchestrator.swift pending its Wave B move), and a
        // public initializer's default-argument expression must not reference a
        // less-visible symbol even within the same module.
        permission: @escaping () -> MicPermissionState = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .authorized
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        },
        pollInterval: TimeInterval = 2.0,
        gracePeriod: TimeInterval = 5.0
    ) {
        self.supervisor = supervisor
        self.registry = registry
        self.processSnapshot = processSnapshot
        self.resolver = resolver
        self.permission = permission
        self.pollInterval = pollInterval
        self.gracePeriod = gracePeriod
    }

    public func start() {
        queue.sync {
            guard !isRunning else { return }
            isRunning = true

            let poll = DispatchSource.makeTimerSource(queue: queue)
            poll.schedule(deadline: .now(), repeating: pollInterval)
            poll.setEventHandler { [weak self] in self?.tick() }
            poll.resume()
            pollTimer = poll

            let perm = DispatchSource.makeTimerSource(queue: queue)
            perm.schedule(deadline: .now(), repeating: 30.0)
            perm.setEventHandler { [weak self] in self?.refreshPermission() }
            perm.resume()
            permissionTimer = perm

            log.notice("lifecycle started — polling every \(pollInterval)s")
        }
    }

    public func stop() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false

            pollTimer?.cancel()
            pollTimer = nil
            permissionTimer?.cancel()
            permissionTimer = nil

            for (_, timer) in drainTimers { timer.cancel() }
            drainTimers.removeAll()

            // Final empty-demand apply — this is how the worker is released (§11.1 C13).
            _ = supervisor.apply(demand: [], now: Date())

            // Close every session that was open or draining.
            for bundleID in arrivedAtByBundleID.keys {
                registry.closeSession(bundleID: bundleID)
            }
            arrivedAtByBundleID.removeAll()
            previousBundleIDs.removeAll()
            knownPIDs.removeAll()

            publish(anySessionOpen: false)
            log.notice("lifecycle stopped")
        }
    }

    // MARK: - Poll tick

    private func tick() {
        let now = Date()
        let processes = processSnapshot()
        for proc in processes { knownPIDs[proc.bundleID] = proc.pid }
        let currentBundleIDs = Set(processes.map(\.bundleID))

        // Demand reflects THIS tick's raw presence. For an app already known, reuse its
        // preserved arrival time; for a brand-new (or not-yet-admitted) app, "now" is its
        // candidate arrival — persisted only once admission actually happens below.
        let demand: [DemandEntry] = processes.map { proc in
            DemandEntry(
                bundleID: proc.bundleID,
                pid: proc.pid,
                arrivedAt: arrivedAtByBundleID[proc.bundleID] ?? now
            )
        }

        let status: CaptureStatus = supervisor.apply(demand: demand, now: now)

        let arrived = currentBundleIDs.subtracting(previousBundleIDs)
        let departed = previousBundleIDs.subtracting(currentBundleIDs)

        if !departed.isEmpty {
            handleDeparted(departed)
        }
        if !arrived.isEmpty, status.isCapturing {
            handleArrived(arrived, now: now)
        }

        previousBundleIDs = currentBundleIDs
        if !arrived.isEmpty, !status.isCapturing {
            // Capture isn't up yet — leave these unseen so the next tick retries them
            // as fresh arrivals (§11.1 C7).
            previousBundleIDs.subtract(arrived)
        }

        publish(anySessionOpen: registry.anySessionOpen || !drainTimers.isEmpty)
    }

    private func handleArrived(_ bundleIDs: Set<String>, now: Date) {
        for bundleID in bundleIDs {
            drainTimers[bundleID]?.cancel()
            drainTimers[bundleID] = nil

            let isReclaim = arrivedAtByBundleID[bundleID] != nil
            if !isReclaim {
                arrivedAtByBundleID[bundleID] = now
            }

            let pid = knownPIDs[bundleID] ?? 0
            let displayName = resolver.resolve(bundleID: bundleID, pid: pid)
            registry.openSession(bundleID: bundleID, displayName: displayName) // idempotent
            log.notice("session \(isReclaim ? "reclaimed" : "opened") — \(displayName) (\(bundleID))")
        }
    }

    private func handleDeparted(_ bundleIDs: Set<String>) {
        for bundleID in bundleIDs {
            guard drainTimers[bundleID] == nil else { continue } // already draining
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + gracePeriod)
            timer.setEventHandler { [weak self] in self?.expireDrain(bundleID: bundleID) }
            timer.resume()
            drainTimers[bundleID] = timer
            log.info("drain started — \(bundleID) grace=\(gracePeriod)s")
        }
    }

    private func expireDrain(bundleID: String) {
        drainTimers[bundleID]?.cancel()
        drainTimers[bundleID] = nil
        registry.closeSession(bundleID: bundleID)
        arrivedAtByBundleID.removeValue(forKey: bundleID)
        knownPIDs.removeValue(forKey: bundleID)
        log.notice("session closed — \(bundleID)")
        publish(anySessionOpen: registry.anySessionOpen || !drainTimers.isEmpty)
    }

    // MARK: - Permission

    private func refreshPermission() {
        publish(micPermission: permission())
    }

    // MARK: - Publish (shadow-copy pattern — safe to call from `queue`)

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
