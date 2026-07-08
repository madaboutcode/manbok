import CoreAudio
import Foundation

// MARK: - CONTRACT: CaptureDevicePolicy
//
// GUARANTEES:
// - Total, deterministic, throws nothing, caches nothing.
// - Selects the single CaptureTarget for current demand, or nil when no device
//   information is available for any demanded app (never falls back to .systemDefault).
// - Pure: no HAL reads, no workers, no state.
//
// DOES NOT: read the HAL, know workers/restarts, hold state, fall back to .systemDefault.

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

    /// Total, deterministic, throws nothing, caches nothing.
    public static func target(demand: [AppDevices]) -> CaptureTarget? {
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

        guard !holderBundleIDs.isEmpty else { return nil }

        // Step 2: score = number of distinct bundleIDs holding the device. Highest wins.
        let maxScore = holderBundleIDs.values.map(\.count).max()!
        let topScoring = holderBundleIDs
            .filter { $0.value.count == maxScore }
            .map(\.key)

        // Step 3: tie → rank each tied device by the latest arrivedAt among the apps
        // holding THAT device. The device whose holders arrived most recently wins.
        let maxArrival = topScoring.compactMap { latestArrival[$0] }.max()!
        let topArrival = topScoring.filter { latestArrival[$0] == maxArrival }

        // Step 4: still tied → lowest AudioDeviceID (deterministic arbitrary).
        let winner = topArrival.min()!
        return .device(winner)
    }
}
