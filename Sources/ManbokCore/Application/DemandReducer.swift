import Foundation

// MARK: - CONTRACT: DemandReducer
//
// PURPOSE: One pure decision per poll: which apps are demand, which devices capture may
// target, and which registry sessions to open or close. No HAL, no timers, no clock reads.
//
// GUARANTEES:
// - step(state, input) -> (state, output) is total and deterministic. `input.now` is monotonic
//   seconds (continuous across sleep); the executor owns the clock.
// - Per app (input holders are already filtered by the executor; h = app is listed):
//     absent  + h  -> holding(arrivedAt = now)
//     holding + h  -> holding (devices refreshed, arrivedAt kept)
//     holding + !h -> draining(kept = last devices, deadline = now + grace)
//     draining + h -> holding (reclaim: arrivedAt kept, session untouched)
//     draining + !h, now >= deadline -> absent, session closed, arrivedAt forgotten
//   An app that is not listed never enters state: no session, no demand (P2a, P2b).
// - Session rule, applied after the transitions in the same step: every non-absent app (holding
//   or draining) without an open session gets one iff input.isCapturing (P4). Sessions are
//   closed only at drain expiry or stop(); a capture outage never closes one.
// - Output.demand has one entry per non-absent app, ordered by appID. `devices` are the capture
//   candidates: a holding app's listed devices; a draining app's kept devices intersected with
//   liveDevices, and only when no holding app lists a device (P5). An app may have no candidate
//   devices; demand is then non-empty with no device (design 4b), and the session stays open.
// - Several observations with one appID merge: devices are united, the last pid wins.
// - Idempotent: step(step(s, i).state, i) equals step(s, i).state and issues no session ops.
//
// EXPECTS:
// - A HolderObservation always has at least one input device (precondition at construction).
// - The executor applies Output.sessionOps to the registry; the reducer is the only opener and
//   closer, so state.sessionOpen equals the registry's open set after every executed step.
//
// DOES NOT: read the HAL, know workers, restarts or watchdogs, apply user exclusions (the
// executor filters holders first), or use IsRunningInput.

public struct HolderObservation: Equatable, Sendable {
    public let appID: String
    public let pid: Int32
    public let inputDevices: Set<UInt32>

    public init(appID: String, pid: Int32, inputDevices: Set<UInt32>) {
        precondition(!inputDevices.isEmpty, "a holder lists at least one input device: \(appID)")
        self.appID = appID
        self.pid = pid
        self.inputDevices = inputDevices
    }
}

public struct DemandInput: Equatable, Sendable {
    public let now: TimeInterval
    public let holders: [HolderObservation]
    public let liveDevices: Set<UInt32>
    public let isCapturing: Bool

    public init(now: TimeInterval, holders: [HolderObservation], liveDevices: Set<UInt32>, isCapturing: Bool) {
        self.now = now
        self.holders = holders
        self.liveDevices = liveDevices
        self.isCapturing = isCapturing
    }
}

public enum AppPhase: Equatable, Sendable {
    case holding(arrivedAt: TimeInterval, pid: Int32, devices: Set<UInt32>)
    case draining(arrivedAt: TimeInterval, pid: Int32, kept: Set<UInt32>, deadline: TimeInterval)
}

public struct DemandState: Equatable, Sendable {
    public var apps: [String: AppPhase]
    public var sessionOpen: Set<String>

    public init(apps: [String: AppPhase] = [:], sessionOpen: Set<String> = []) {
        self.apps = apps
        self.sessionOpen = sessionOpen
    }

    public static let empty = DemandState()
}

public struct DemandApp: Equatable, Sendable {
    public let appID: String
    public let pid: Int32
    public let arrivedAt: TimeInterval
    public let devices: Set<UInt32>
    public let isDraining: Bool

    public init(appID: String, pid: Int32, arrivedAt: TimeInterval, devices: Set<UInt32>, isDraining: Bool) {
        self.appID = appID
        self.pid = pid
        self.arrivedAt = arrivedAt
        self.devices = devices
        self.isDraining = isDraining
    }
}

public enum SessionOp: Equatable, Sendable {
    case open(appID: String, pid: Int32)
    case close(appID: String)
}

public struct DemandOutput: Equatable, Sendable {
    public let demand: [DemandApp]
    public let sessionOps: [SessionOp]
}

public struct DemandReducer: Sendable {
    public let grace: TimeInterval

    public init(grace: TimeInterval) {
        self.grace = grace
    }

    public func step(_ state: DemandState, _ input: DemandInput) -> (DemandState, DemandOutput) {
        var next = state
        var ops: [SessionOp] = []
        let listed = Self.merge(input.holders)

        for (appID, phase) in state.apps where listed[appID] == nil {
            guard case .holding(let arrivedAt, let pid, let devices) = phase else { continue }
            next.apps[appID] = .draining(arrivedAt: arrivedAt, pid: pid, kept: devices, deadline: input.now + grace)
        }
        for (appID, obs) in listed {
            var arrivedAt = input.now
            switch state.apps[appID] {
            case .holding(let t, _, _), .draining(let t, _, _, _): arrivedAt = t
            case nil: break
            }
            next.apps[appID] = .holding(arrivedAt: arrivedAt, pid: obs.pid, devices: obs.inputDevices)
        }
        for appID in next.apps.keys.sorted() {
            guard case .draining(_, _, _, let deadline) = next.apps[appID], input.now >= deadline else { continue }
            next.apps[appID] = nil
            if next.sessionOpen.remove(appID) != nil { ops.append(.close(appID: appID)) }
        }

        let demand = Self.demand(next.apps, live: input.liveDevices)

        if input.isCapturing {
            for app in demand where !next.sessionOpen.contains(app.appID) {
                next.sessionOpen.insert(app.appID)
                ops.append(.open(appID: app.appID, pid: app.pid))
            }
        }
        return (next, DemandOutput(demand: demand, sessionOps: ops))
    }

    /// Manbok stop: every app becomes absent and every open session closes.
    public func stop(_ state: DemandState) -> (DemandState, [SessionOp]) {
        (.empty, state.sessionOpen.sorted().map { .close(appID: $0) })
    }

    private static func merge(_ holders: [HolderObservation]) -> [String: HolderObservation] {
        var merged: [String: HolderObservation] = [:]
        for h in holders {
            if let existing = merged[h.appID] {
                merged[h.appID] = HolderObservation(
                    appID: h.appID, pid: h.pid, inputDevices: existing.inputDevices.union(h.inputDevices))
            } else {
                merged[h.appID] = h
            }
        }
        return merged
    }

    private static func demand(_ apps: [String: AppPhase], live: Set<UInt32>) -> [DemandApp] {
        let anyHolderListsDevice = apps.values.contains {
            if case .holding(_, _, let devices) = $0 { return !devices.isEmpty }
            return false
        }
        return apps.keys.sorted().map { appID in
            switch apps[appID]! {
            case .holding(let arrivedAt, let pid, let devices):
                return DemandApp(appID: appID, pid: pid, arrivedAt: arrivedAt, devices: devices, isDraining: false)
            case .draining(let arrivedAt, let pid, let kept, _):
                let candidates = anyHolderListsDevice ? [] : kept.intersection(live)
                return DemandApp(appID: appID, pid: pid, arrivedAt: arrivedAt, devices: candidates, isDraining: true)
            }
        }
    }
}
