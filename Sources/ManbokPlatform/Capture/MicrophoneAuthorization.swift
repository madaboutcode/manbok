import AVFoundation
import Foundation

// MARK: - CONTRACT (MicrophoneAuthorization)
//
// GUARANTEES
// - Reports macOS microphone TCC state for the running binary.
// - `ensureAuthorized()` blocks until determined when status is notDetermined and may show the system prompt.
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