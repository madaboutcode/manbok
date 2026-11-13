import AVFoundation
import Foundation

// MARK: - CONTRACT (MicrophoneAuthorization)
//
// GUARANTEES
// - Reports macOS microphone TCC state for the running binary.
// - `ensureAuthorized()` blocks until determined when status is notDetermined and may show the system prompt.
//   Only the CLI (its own thread) may call it; the app's capture path uses `MicrophoneAuthorizing.requestAccess`,
//   which returns at once and answers later.
//
// DOES NOT
// - Start AVAudioEngine or touch the ring buffer.

public enum MicrophoneAuthorizationStatus: Sendable, Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

public enum MicrophoneAuthorization {
    public static func currentStatus() -> MicrophoneAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Returns true when capture is allowed. When `notDetermined`, requests access (system dialog).
    @discardableResult
    public static func ensureAuthorized() -> Bool {
        switch currentStatus() {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            return granted
        case .denied, .restricted:
            return false
        }
    }

    public static let settingsHint =
        "Grant Microphone access in System Settings → Privacy & Security → Microphone (enable manbok)."
}

/// Boundary to the macOS microphone permission (TCC). `requestAccess` never blocks: the answer
/// arrives on an arbitrary thread when the user closes the prompt.
public protocol MicrophoneAuthorizing: AnyObject {
    var status: MicrophoneAuthorizationStatus { get }
    func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void)
}

public final class SystemMicrophoneAuthorizer: MicrophoneAuthorizing {
    public init() {}
    public var status: MicrophoneAuthorizationStatus { MicrophoneAuthorization.currentStatus() }
    public func requestAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }
}
