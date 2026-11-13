import Foundation

// MARK: - CONTRACT: SilenceAlarmPolicy
//
// PURPOSE: Decide when to tell the user that the mic delivers nothing while an app is using it.
// Pure: no clock reads, no I/O. The caller passes `now` (monotonic seconds) with every input.
//
// GUARANTEES:
// - Alarm condition: at least one session is open AND no audible chunk arrived for `duration`
//   seconds. "Audible" is decided by the caller (peak > 0, the floor the digital-silence watchdog
//   uses); a missing chunk (stalled or restarting capture) counts as silence, so a restart does
//   not reset the clock.
// - The silence clock starts at the later of the sessions-open transition (none -> some) and the
//   last audible chunk. It runs whether or not the alarm is enabled.
// - step(.tick) raises once per silent stretch, when now - clockStart >= duration and the alarm is
//   enabled. Further ticks in the same stretch return .none.
// - A raised alarm clears on an audible chunk, when the last session closes, or when the alarm is
//   disabled. After clearing, a new stretch may raise again.
// - A duration change applies at the next tick; it never re-raises a raised alarm.
// - An audible chunk while no session is open is ignored (the open transition restarts the clock).
//
// EXPECTS:
// - `now` never decreases between calls (precondition).
// - The caller reports the sessions-open transition through .sessionsOpen(true/false); repeating
//   the same value is a no-op.
//
// DOES NOT: decide audibility, know devices, apps or notifications, or tick on its own.

public struct SilenceAlarmConfig: Equatable, Sendable {
    public static let durationChoices: [Int] = [10, 20, 30, 60, 120, 300]
    public static let defaultSeconds = 30

    public var enabled: Bool
    public var seconds: Int

    public init(enabled: Bool, seconds: Int) {
        precondition(Self.durationChoices.contains(seconds), "silence alarm seconds not a choice: \(seconds)")
        self.enabled = enabled
        self.seconds = seconds
    }

    public static let `default` = SilenceAlarmConfig(enabled: false, seconds: defaultSeconds)
}

public enum SilenceAlarmInput: Equatable, Sendable {
    case audibleChunk
    case sessionsOpen(Bool)
    case tick
    case config(SilenceAlarmConfig)
}

public enum SilenceAlarmClearReason: String, Equatable, Sendable {
    case audible = "sound returned"
    case sessionsClosed = "no session open"
    case disabled = "alarm switched off"
}

public enum SilenceAlarmOutput: Equatable, Sendable {
    case none
    case raise(silentFor: TimeInterval)
    case clear(SilenceAlarmClearReason)
}

public struct SilenceAlarmPolicy: Equatable, Sendable {
    public private(set) var config: SilenceAlarmConfig
    public private(set) var isRaised = false
    private var sessionsAreOpen = false
    private var clockStart: TimeInterval = 0
    private var lastNow: TimeInterval = -.infinity

    public init(config: SilenceAlarmConfig = .default) {
        self.config = config
    }

    public mutating func step(_ input: SilenceAlarmInput, now: TimeInterval) -> SilenceAlarmOutput {
        precondition(now >= lastNow, "time went backwards: \(now) < \(lastNow)")
        lastNow = now

        switch input {
        case .sessionsOpen(let open):
            guard open != sessionsAreOpen else { return .none }
            sessionsAreOpen = open
            if open {
                clockStart = now
                return .none
            }
            return clearIfRaised(.sessionsClosed)

        case .audibleChunk:
            guard sessionsAreOpen else { return .none }
            clockStart = now
            return clearIfRaised(.audible)

        case .tick:
            guard config.enabled, sessionsAreOpen, !isRaised else { return .none }
            let silentFor = now - clockStart
            guard silentFor >= TimeInterval(config.seconds) else { return .none }
            isRaised = true
            return .raise(silentFor: silentFor)

        case .config(let new):
            let wasEnabled = config.enabled
            config = new
            if wasEnabled && !new.enabled { return clearIfRaised(.disabled) }
            return .none
        }
    }

    private mutating func clearIfRaised(_ reason: SilenceAlarmClearReason) -> SilenceAlarmOutput {
        guard isRaised else { return .none }
        isRaised = false
        return .clear(reason)
    }
}
