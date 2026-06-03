import Foundation

// MARK: - CONTRACT (AudioCapturing)
//
// GUARANTEES
// - Implementations deliver canonical PCM (s16le 16 kHz mono) to sink.
// - No sink calls after stop().
//
// EXPECTS
// - sink is invoked on the capture/audio thread; callers serialize if needed.
//
// FAILURE BEHAVIOR
// - start throws if permission denied or capture hardware cannot start.
//
// DOES NOT
// - Buffer more than one chunk internally, write files, or touch the ring.

/// Port for continuous microphone capture into canonical PCM chunks.
public protocol AudioCapturing: AnyObject {
    func start(sink: @escaping (Data) -> Void) throws
    func stop()
}