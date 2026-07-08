import Foundation
import CoreAudio

// MARK: - CONTRACT: CaptureWaist
//
// PURPOSE: Single file owning every symbol the lifecycle half may share with the
// capture-supervision half. Enforced by a source-scan test (denylist of capture-side
// identifiers in SessionLifecycleController.swift).
//
// GUARANTEES:
// - DemandEntry: one per external app currently holding the mic.
// - CaptureHealth: four states (idle, capturing, recovering, holdingSilent).
// - CaptureStatus: post-tick status returned from apply().
// - CaptureSupervising: the ONLY downward waist protocol (lifecycle → supervisor).
//
// DOES NOT: contain worker types, policy types, backend types, or device types.

/// Demand: one entry per external app (bundleID) currently holding the mic.
public struct DemandEntry: Equatable, Sendable {
    public let bundleID: String
    public let pid: pid_t          // representative pid (most recently seen)
    public let arrivedAt: Date     // first tick of session-continuous presence;
                                   // preserved across depart-and-reclaim within drain;
                                   // reset only after drain actually expires

    public init(bundleID: String, pid: pid_t, arrivedAt: Date) {
        self.bundleID = bundleID
        self.pid = pid
        self.arrivedAt = arrivedAt
    }
}

public enum CaptureHealth: Equatable, Sendable {
    case idle              // no demand, no worker
    case capturing         // worker running, both watchdogs quiet
    case recovering        // restart pending/backoff (stall, silence, target change)
    case holdingSilent     // R5 Holding: capturing, silence ladder exhausted
}

public struct CaptureStatus: Equatable, Sendable {
    public let isCapturing: Bool   // lifecycle's arrivals-deferred gate reads this
    public let health: CaptureHealth

    public init(isCapturing: Bool, health: CaptureHealth) {
        self.isCapturing = isCapturing
        self.health = health
    }
}

/// The ONLY downward waist call. Lifecycle calls it once per poll tick (and once
/// with [] from stop()). Synchronous: status reflects this tick's decisions.
public protocol CaptureSupervising: AnyObject {
    func apply(demand: [DemandEntry], now: Date) -> CaptureStatus
}
