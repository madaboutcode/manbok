import Combine
import Foundation
import ManbokCore

// MARK: - CONTRACT: SilenceAlarmMonitor
//
// PURPOSE: Runs SilenceAlarmPolicy against live inputs, and turns its decisions into a published
// state, a system notification and log lines.
//
// GUARANTEES:
// - Inputs: audibleChunk() from the capture path, sessionsOpen(_:) (bound to the lifecycle's
//   anySessionOpen), configure(_:) from settings, and a tick every `tickInterval` while started.
//   Each input is stepped with the injected monotonic clock, under one lock, so inputs from
//   several threads reach the policy in clock order.
// - On raise: asks `context` for the open apps and the bound device, posts one notice through the
//   notifier, logs one .capture notice, and publishes `status`. On clear: withdraws the notice,
//   logs one .capture notice with the reason, and sets `status` to nil.
// - Switching the alarm on (off -> on after init) asks the notifier for authorization once per
//   switch. The initial config given to init never does.
// - `status` is written on the main queue only.
//
// DOES NOT: decide when silence is alarming (SilenceAlarmPolicy), decide audibility (the caller),
// read the clock itself beyond the injected closure, or touch audio devices.

public struct SilenceAlarmStatus: Equatable, Sendable {
    public let device: String
    public let seconds: Int
}

public final class SilenceAlarmMonitor: ObservableObject, @unchecked Sendable {
    public typealias Context = () -> (apps: [String], device: String)

    private let lock = NSLock()
    private var policy: SilenceAlarmPolicy
    private let clock: () -> TimeInterval
    private let notifier: SilenceAlarmNotifying
    private let context: Context
    private let tickInterval: TimeInterval
    private let queue = DispatchQueue(label: "ai.manbok.app.silence-alarm", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var sessionsCancellable: AnyCancellable?
    private let log = AppLog(category: .capture)

    @Published public private(set) var status: SilenceAlarmStatus?

    public init(
        config: SilenceAlarmConfig,
        notifier: SilenceAlarmNotifying,
        context: @escaping Context,
        tickInterval: TimeInterval = 2.0,
        clock: @escaping () -> TimeInterval = {
            TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        }
    ) {
        self.policy = SilenceAlarmPolicy(config: config)
        self.notifier = notifier
        self.context = context
        self.tickInterval = tickInterval
        self.clock = clock
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// Follows the lifecycle's session-open flag. The publisher replays its current value.
    public func bind(sessionsOpen publisher: Published<Bool>.Publisher) {
        sessionsCancellable = publisher.sink { [weak self] open in self?.sessionsOpen(open) }
    }

    public func audibleChunk() { apply(.audibleChunk) }
    public func sessionsOpen(_ open: Bool) { apply(.sessionsOpen(open)) }
    public func tick() { apply(.tick) }

    public func configure(_ config: SilenceAlarmConfig) {
        lock.lock()
        let wasEnabled = policy.config.enabled
        lock.unlock()
        if config.enabled && !wasEnabled { notifier.requestAuthorization() }
        apply(.config(config))
    }

    private func apply(_ input: SilenceAlarmInput) {
        lock.lock()
        defer { lock.unlock() }
        switch policy.step(input, now: clock()) {
        case .none:
            break
        case .raise(let silentFor):
            let (apps, device) = context()
            let seconds = policy.config.seconds
            log.notice("silent-mic alarm raised — \(apps.joined(separator: ", ")) on \(device), silent \(Int(silentFor)) s")
            notifier.post(SilenceAlarmNotice(apps: apps, device: device, silentSeconds: seconds))
            publish(SilenceAlarmStatus(device: device, seconds: seconds))
        case .clear(let reason):
            log.notice("silent-mic alarm cleared — \(reason.rawValue)")
            notifier.withdraw()
            publish(nil)
        }
    }

    private func publish(_ value: SilenceAlarmStatus?) {
        DispatchQueue.main.async { [weak self] in self?.status = value }
    }
}
