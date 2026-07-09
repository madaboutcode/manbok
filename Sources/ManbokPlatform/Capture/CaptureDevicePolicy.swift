import CoreAudio
import Foundation

// MARK: - CONTRACT: CaptureDevicePolicy
//
// GUARANTEES:
// - Total, deterministic, throws nothing, caches nothing.
// - Selects the single CaptureTarget for current demand, or nil when no device
//   information is available for any demanded app (never falls back to .systemDefault).
// - Tie-break when multiple devices score equally (same distinct-bundleID holder
//   count, same latest arrival):
//     1. If currentTarget is among the tied candidates AND there is exactly one
//        other tied candidate, prefer the OTHER (non-current) device — its presence
//        in the demanded app's own per-process device list is itself evidence that
//        app has engaged it on the input side, the strongest signal of intent available.
//     2. Otherwise (no currentTarget — cold start; or a 3+-way tie): lowest
//        AudioDeviceID, deterministic last resort, unchanged from before.
// - Pure: no HAL reads, no workers, no state. currentTarget is an explicit input,
//   not held state — same status as demand.
//
// EXPECTS: currentTarget, when non-nil, reflects what is actually being recorded at
//   the moment of the call. Caller's responsibility — CaptureSupervisor already owns
//   this value as workerTarget.
//
// DOES NOT: read the HAL, know workers/restarts, hold state, fall back to
//   .systemDefault, or use device transport type as a selection signal.
//
// KNOWN LIMITATIONS: cannot distinguish "app deliberately moved its real capture to
//   the new device" from "app's audio subsystem opened some other, non-content-bearing
//   relationship with the new device" — both look identical in pdv#; resolved in favor
//   of following the app's newest relationship, a deliberate trade-off. Does no good
//   for apps whose live stream never updates its own pdv# relationship on a device
//   change (observed: Firefox) — explicitly out of scope.

public enum CaptureDevicePolicy {
    public struct AppDevices: Equatable, Sendable {
        public let bundleID: String
        public let arrivedAt: Date
        public let deviceIDs: [AudioDeviceID]  // input devices open via pdv#; may be []

        public init(bundleID: String, arrivedAt: Date, deviceIDs: [AudioDeviceID]) {
            self.bundleID = bundleID
            self.arrivedAt = arrivedAt
            self.deviceIDs = deviceIDs
        }
    }

    /// Which step-4 rule produced the pick. Observability only (drives CaptureSupervisor's
    /// restart-trigger logging) — never affects the decision itself.
    enum TieBreakBranch: Equatable, Sendable {
        case noTie                 // single top candidate — step 4 never ran
        case newestRelationship    // 2-way tie, currentTarget among candidates — picked the other
        case lowestIDFallback      // cold start (no currentTarget) or a 3+-way tie
    }

    /// Total, deterministic, throws nothing, caches nothing.
    public static func target(demand: [AppDevices], currentTarget: CaptureTarget?) -> CaptureTarget? {
        resolve(demand: demand, currentTarget: currentTarget).target
    }

    /// Same decision as `target`, plus which tie-break rule fired — for callers (namely
    /// CaptureSupervisor) that want to log the branch without recomputing steps 1-3.
    static func resolve(demand: [AppDevices], currentTarget: CaptureTarget?) -> (target: CaptureTarget?, tieBreak: TieBreakBranch) {
        // Step 1: candidates = union of all deviceIDs across all demanded apps.
        // Also track, per candidate device, the distinct bundleIDs holding it and the
        // latest arrivedAt among those holders. Apps with deviceIDs == [] contribute
        // nothing here and therefore never influence scoring or the tie-break.
        var holderBundleIDs: [AudioDeviceID: Set<String>] = [:]
        var latestArrival: [AudioDeviceID: Date] = [:]

        for app in demand {
            for device in Set(app.deviceIDs) {
                holderBundleIDs[device, default: []].insert(app.bundleID)
                if let existing = latestArrival[device] {
                    latestArrival[device] = max(existing, app.arrivedAt)
                } else {
                    latestArrival[device] = app.arrivedAt
                }
            }
        }

        guard !holderBundleIDs.isEmpty else { return (nil, .noTie) }

        // Step 2: score = number of distinct bundleIDs holding the device. Highest wins.
        let maxScore = holderBundleIDs.values.map(\.count).max()!
        let topScoring = holderBundleIDs
            .filter { $0.value.count == maxScore }
            .map(\.key)

        // Step 3: tie → rank each tied device by the latest arrivedAt among the apps
        // holding THAT device. The device whose holders arrived most recently wins.
        let maxArrival = topScoring.compactMap { latestArrival[$0] }.max()!
        let topArrival = topScoring.filter { latestArrival[$0] == maxArrival }

        if topArrival.count == 1 {
            return (.device(topArrival[0]), .noTie)
        }

        // Step 4a: clean 2-way tie where currentTarget is one of the candidates →
        // prefer the OTHER device (see CONTRACT). Otherwise fall through to 4b.
        if case .device(let current) = currentTarget,
           topArrival.contains(current),
           topArrival.count == 2 {
            let other = topArrival.first { $0 != current }!
            return (.device(other), .newestRelationship)
        }

        // Step 4b: still tied → lowest AudioDeviceID (deterministic last resort).
        let winner = topArrival.min()!
        return (.device(winner), .lowestIDFallback)
    }
}
