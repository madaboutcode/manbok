import Foundation
import CoreAudio

// MARK: - CONTRACT: PinnedAudioCapturing
//
// PURPOSE: Protocol boundary for the audio capture worker. Any backend (AUHAL,
// AVCaptureSession) conforms to this. The supervisor creates workers through an
// injected factory — the unit-test seam and the backend switch point.
//
// GUARANTEES:
// - CaptureTarget: systemDefault or device(AudioDeviceID).
// - CaptureChunk: canonical PCM (s16le 16kHz mono) + peak sample.
// - PinnedCaptureError: typed start failures.
// - PinnedAudioCapturing: disposable worker — one start per instance.
//
// EXPECTS:
// - Exactly one start per instance; a restart means a NEW instance.
// - sink is fast or dispatches. start/stop called from one caller thread.
//
// DOES NOT: retry, observe devices, own policy, buffer beyond one chunk, or touch
// the registry.

public enum CaptureTarget: Equatable, Sendable {
    case systemDefault             // resolve current default AT START, bind concretely
    case device(AudioDeviceID)     // pin; IDs unstable across BT reconnects — resolved fresh
}

public struct CaptureChunk: Sendable {
    public let pcm: Data           // canonical s16le 16kHz mono
    public let peak: Int16         // peak == 0 iff every sample is exactly zero

    public init(pcm: Data, peak: Int16) {
        self.pcm = pcm
        self.peak = peak
    }
}

public enum PinnedCaptureError: Error, Equatable {
    case permissionDenied
    case deviceUnavailable(AudioDeviceID)  // pinned device absent/unusable at start
    case backendFailure(String)            // unit/session error, OSStatus in message
}

public protocol PinnedAudioCapturing: AnyObject {
    /// Start capturing to the given target. Delivers canonical PCM chunks to sink
    /// on the worker's own delivery thread. Disposable: exactly one start per instance.
    func start(target: CaptureTarget, sink: @escaping (CaptureChunk) -> Void) throws

    /// Idempotent barrier — no sink calls after stop() returns.
    func stop()

    /// Concrete device after successful start (D6). Non-nil and constant until stop().
    var boundDevice: AudioDeviceID? { get }
}
