import Foundation

// MARK: - CONTRACT (AppShutdown)
//
// GUARANTEES
// - `perform` runs `lifecycle.stop()`, then `supervisor.stop()`, then `checkpoint()`, in that order, when the
//   stops return within the budget.
// - The checkpoint runs regardless of the stops: if they have not returned after `stopBudget` (2 s total for
//   both), `checkpoint()` runs anyway and an `.error` line says so. The outcome is always logged at a
//   persisted level (.notice for a clean stop, .error for a stuck one).
// - Calls to `checkpoint()` through `perform` are serialized, so two shutdown paths (IPC STOP, Quit) never
//   interleave snapshot-and-save.
//
// EXPECTS
// - `checkpoint` snapshots and saves on its own and does not call back into `perform`.
//
// FAILURE BEHAVIOR
// - A stop that never returns is abandoned on its background thread; `perform` does not wait for it again.
//
// DOES NOT
// - Terminate the process or reply to IPC clients (the caller does).

public enum AppShutdown {
    private static let log = AppLog(category: .app)
    private static let checkpointLock = NSLock()
    private static let stopBudget: TimeInterval = 2

    public static func perform(
        lifecycle: SessionLifecycleController,
        supervisor: CaptureSupervisor,
        checkpoint: () -> Void
    ) {
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            lifecycle.stop()
            supervisor.stop()
            stopped.signal()
        }
        if stopped.wait(timeout: .now() + stopBudget) == .success {
            log.notice("shutdown: lifecycle and supervisor stopped; saving checkpoint")
        } else {
            log.error("shutdown: stop did not return within \(Int(stopBudget)) s (worker or lifecycle queue stuck); saving checkpoint anyway")
        }
        checkpointLock.lock()
        defer { checkpointLock.unlock() }
        checkpoint()
    }
}
