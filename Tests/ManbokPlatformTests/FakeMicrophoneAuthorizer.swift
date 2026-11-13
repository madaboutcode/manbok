import Foundation
@testable import ManbokPlatform

/// Never touches TCC. `requestAccess` records the completion and does not answer until `answer(_:)`.
final class FakeMicrophoneAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: MicrophoneAuthorizationStatus
    private var completions: [@Sendable (Bool) -> Void] = []
    private var _requestCount = 0

    init(status: MicrophoneAuthorizationStatus) { _status = status }

    var status: MicrophoneAuthorizationStatus {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }

    func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); _requestCount += 1; completions.append(completion); lock.unlock()
    }

    /// Plays the user's answer: updates status, then fires every pending completion.
    func answer(_ granted: Bool) {
        lock.lock()
        _status = granted ? .authorized : .denied
        let pending = completions
        completions = []
        lock.unlock()
        pending.forEach { $0(granted) }
    }
}
