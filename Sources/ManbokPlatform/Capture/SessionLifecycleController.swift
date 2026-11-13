import AVFoundation
import Combine
import Foundation
import ManbokCore

// MARK: - CONTRACT: SessionLifecycleController
//
// PURPOSE: The stable half — owns the poll timer, executes DemandReducer decisions (registry
// open/close), and publishes UI state. Talks to capture supervision ONLY through the
// CaptureSupervising waist protocol.
//
// GUARANTEES:
// - Owns the poll timer (~2s) on its serial queue. Each tick: one holder snapshot → DemandReducer.step
//   → supervisor.apply(demand:now:) → execute the reducer's session ops. If apply changed
//   isCapturing, step runs once more in the same tick (same snapshot, same now) and its ops
//   are executed too.
// - Applies HolderExclusion (built-in + user groups) once per snapshot, before the reducer.
//   setExcludedGroups(_:) takes effect on an immediate extra tick while running (no wait for the
//   timer). An app excluded mid-session simply stops being listed: it drains and its session closes
//   at expiry; capture continues for other holders.
// - Publishes holdingNow: every non-built-in holder in the raw snapshot (before user exclusion),
//   one per app group, for the Settings list; updated only when it changes.
// - Drain, reclaim, arrivedAt and the session rule live in DemandReducer (see its CONTRACT). This
//   type keeps no per-app timers and no presence diff; time is a monotonic clock closure.
// - Logs one persisted (.notice) line per reducer transition and per session open/close, from this
//   type only; unchanged polls log nothing.
// - Invariant: the registry's open sessions are exactly the reducer's sessionOpen set after every
//   tick. The reducer is the only opener and closer.
// - DemandEntry.arrivedAt is wall-clock (Date): a fixed origin plus the reducer's monotonic arrival.
// - anySessionOpen = registry.anySessionOpen (an open session covers holding and draining apps).
// - micPermission refreshed via permission() at 30s cadence.
// - permissionDidChange(): refreshes micPermission and runs one tick at once (no wait for the timer)
//   while running; used when a permission request is answered. A tick never waits for the user.
// - stop(): cancel timers, final supervisor.apply(demand: [], now:), close every open session,
//   publish anySessionOpen=false. Composition root then calls supervisor.stop().
//
// EXPECTS:
// - start/stop idempotent, any thread. Supervisor synchronous per §11.1. holderSnapshot returns
//   holders with user exclusions already applied by the caller (none exist yet).
//
// FAILURE:
// - None of its own; capture failures reach it ONLY as isCapturing=false (sessions defer).
//
// DOES NOT: touch devices, workers, watchdogs, restart or silence policy — its only
// capture knowledge is the waist. Enforced by the §11.1 source-scan test.

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

/// Per-app session lifecycle: each poll feeds one holder snapshot to `DemandReducer`, passes its demand
/// into the capture waist and executes its session ops on SessionRegistry. The volatile half (workers,
/// devices, watchdogs, recovery) is entirely behind `CaptureSupervising` — this type never sees it.
///
/// @unchecked Sendable: all mutable state is confined to `queue`, except the @Published
/// properties, which are written only on the main queue (shadow-copy publish pattern).
public final class SessionLifecycleController: ObservableObject, @unchecked Sendable {
    // Dependencies (injected)
    private let supervisor: CaptureSupervising
    private let registry: SessionRegistry
    private let holderSnapshot: () -> HolderSnapshot
    private let resolver: AppIdentityResolver
    private let permission: () -> MicPermissionState
    private let pollInterval: TimeInterval
    private let reducer: DemandReducer
    private let monotonicNow: () -> TimeInterval
    private var exclusion: HolderExclusion

    private let log = AppLog(category: .capture)
    private let queue = DispatchQueue(label: "ai.manbok.app.lifecycle", qos: .userInitiated)

    private var pollTimer: DispatchSourceTimer?
    private var permissionTimer: DispatchSourceTimer?
    private var isRunning = false

    private var demandState = DemandState.empty
    private var lastCapturing = false
    // Wall-clock time of monotonic zero, fixed at the first tick so DemandEntry.arrivedAt is
    // stable across ticks (a per-tick conversion would jitter).
    private var wallOrigin: Date?

    // Shadow copies — publish() is called from `queue`, so it must not read the
    // @Published properties themselves (those are written on the main queue).
    private var anySessionOpenLocal = false
    private var micPermissionLocal = MicPermissionState.notDetermined

    private var holdingNowLocal: [ActiveHolder] = []

    @Published public private(set) var holdingNow: [ActiveHolder] = []
    @Published public private(set) var anySessionOpen: Bool = false
    @Published public private(set) var micPermission: MicPermissionState = .notDetermined

    public init(
        supervisor: CaptureSupervising,
        registry: SessionRegistry,
        holderSnapshot: @escaping () -> HolderSnapshot,
        resolver: AppIdentityResolver = .shared,
        // Inlined rather than calling MicPermissionState.from(_:): that static method is
        // `internal`, and a public initializer's default-argument expression must not
        // reference a less-visible symbol even within the same module.
        permission: @escaping () -> MicPermissionState = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .authorized
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        },
        pollInterval: TimeInterval = 2.0,
        gracePeriod: TimeInterval = 5.0,
        excludedGroups: Set<String> = [],
        // CLOCK_MONOTONIC_RAW keeps counting while the Mac sleeps, so a sleep longer than the
        // grace period expires drains on the first poll after wake.
        monotonicNow: @escaping () -> TimeInterval = {
            TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        }
    ) {
        self.supervisor = supervisor
        self.registry = registry
        self.holderSnapshot = holderSnapshot
        self.resolver = resolver
        self.permission = permission
        self.pollInterval = pollInterval
        self.reducer = DemandReducer(grace: gracePeriod)
        self.monotonicNow = monotonicNow
        self.exclusion = HolderExclusion(userGroups: excludedGroups)
    }

    /// Replaces the user's excluded app groups; while running, polls immediately.
    public func setExcludedGroups(_ groups: Set<String>) {
        queue.async { [self] in
            guard exclusion.userGroups != groups else { return }
            exclusion = HolderExclusion(userGroups: groups)
            if isRunning { tick() }
        }
    }

    /// A permission request was answered: publish the new state and step now.
    public func permissionDidChange() {
        queue.async { [self] in
            guard isRunning else { return }
            refreshPermission()
            tick()
        }
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

            // Final empty-demand apply — this is how the worker is released (§11.1 C13).
            _ = supervisor.apply(demand: [], now: Date())

            let (cleared, closes) = reducer.stop(demandState)
            execute(closes)
            demandState = cleared
            lastCapturing = false
            wallOrigin = nil

            publish(anySessionOpen: false)
            publish(holdingNow: [])
            log.notice("lifecycle stopped")
        }
    }

    // MARK: - Poll tick

    private func tick() {
        let snapshot = holderSnapshot()
        let mono = monotonicNow()
        let wall = Date()
        let origin = wallOrigin ?? wall.addingTimeInterval(-mono)
        wallOrigin = origin
        let holders = snapshot.holders.filter { !exclusion.isExcluded($0.appID) }
        publish(holdingNow: activeHolders(snapshot.holders))
        func input(capturing: Bool) -> DemandInput {
            DemandInput(now: mono, holders: holders, liveDevices: snapshot.liveInputDevices, isCapturing: capturing)
        }

        let (afterStep, output) = reducer.step(demandState, input(capturing: lastCapturing))
        let entries = output.demand.map {
            DemandEntry(
                bundleID: $0.appID,
                pid: $0.pid,
                arrivedAt: origin.addingTimeInterval($0.arrivedAt),
                deviceIDs: $0.devices
            )
        }
        let status: CaptureStatus = supervisor.apply(demand: entries, now: wall)
        demandState = afterStep
        report(output.transitions, now: mono)
        execute(output.sessionOps)

        if status.isCapturing != lastCapturing {
            lastCapturing = status.isCapturing
            let (afterRecheck, recheck) = reducer.step(demandState, input(capturing: status.isCapturing))
            demandState = afterRecheck
            report(recheck.transitions, now: mono)
            execute(recheck.sessionOps)
        }

        publish(anySessionOpen: registry.anySessionOpen)
    }

    private func activeHolders(_ raw: [HolderObservation]) -> [ActiveHolder] {
        var seen = Set<String>()
        var result: [ActiveHolder] = []
        for h in raw where !HolderExclusion.isBuiltIn(h.appID) {
            let group = appGroup(h.appID)
            guard seen.insert(group).inserted else { continue }
            result.append(ActiveHolder(group: group, bundleID: h.appID, displayName: resolver.resolve(bundleID: h.appID, pid: h.pid)))
        }
        return result
    }

    private func report(_ transitions: [AppTransition], now: TimeInterval) {
        for transition in transitions {
            switch transition {
            case .startedHolding(let appID, let devices):
                log.notice("app holding mic — \(appID) devices=\(devices.sorted())")
            case .drainStarted(let appID, let kept, let deadline):
                log.notice("app stopped holding — \(appID) kept=\(kept.sorted()) closes in \(String(format: "%.1f", deadline - now))s unless it returns")
            case .reclaimed(let appID):
                log.notice("app returned within grace — \(appID) (same session)")
            case .drainExpired(let appID):
                log.notice("app released — \(appID) (grace expired)")
            }
        }
    }

    private func execute(_ ops: [SessionOp]) {
        for op in ops {
            switch op {
            case .open(let appID, let pid):
                let displayName = resolver.resolve(bundleID: appID, pid: pid)
                registry.openSession(bundleID: appID, displayName: displayName)
                log.notice("session opened — \(displayName) (\(appID))")
            case .close(let appID):
                registry.closeSession(bundleID: appID)
                log.notice("session closed — \(appID)")
            }
        }
    }

    /// Test seams: one synchronous tick, and the reducer's view of open sessions.
    func pollOnce() { queue.sync { tick() } }
    var reducerOpenSessions: Set<String> { queue.sync { demandState.sessionOpen } }

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

    private func publish(holdingNow value: [ActiveHolder]) {
        guard holdingNowLocal != value else { return }
        holdingNowLocal = value
        DispatchQueue.main.async { [weak self] in self?.holdingNow = value }
    }

    private func publish(micPermission value: MicPermissionState) {
        guard micPermissionLocal != value else { return }
        micPermissionLocal = value
        DispatchQueue.main.async { [weak self] in self?.micPermission = value }
    }
}
