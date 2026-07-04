import Foundation

// MARK: - CONTRACT (ActivityPresenting)
//
// GUARANTEES
// - `start`/`stop` bracket daemon lifetime for optional live UI.
// - Null implementation is no-op (detached daemon).
//
// DOES NOT
// - Capture audio or interpret speech activity.

public protocol ActivityPresenting: AnyObject {
    func start()
    func stop()
}

/// Detached daemon: no terminal activity UI.
public final class NullActivityPresenter: ActivityPresenting {
    public init() {}
    public func start() {}
    public func stop() {}
}