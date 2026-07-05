import Foundation

/// One captured session slice in the ring (stable id assigned at session open).
public struct SessionSummary: Sendable, Equatable {
    public let id: UInt64
    public let audioBytes: Int
    public let durationSeconds: Double
    /// Seconds before `now` that capture for this session began.
    public let startedSecondsAgo: TimeInterval
    /// Seconds before `now` the session ended; nil while still recording.
    public let endedSecondsAgo: TimeInterval?
    public let isOpen: Bool
    /// Human-readable name of the app(s) that triggered this session (e.g. "Zoom", "FaceTime, OBS").
    public let appName: String?

    public init(
        id: UInt64,
        audioBytes: Int,
        durationSeconds: Double,
        startedSecondsAgo: TimeInterval,
        endedSecondsAgo: TimeInterval?,
        isOpen: Bool,
        appName: String? = nil
    ) {
        self.id = id
        self.audioBytes = audioBytes
        self.durationSeconds = durationSeconds
        self.startedSecondsAgo = startedSecondsAgo
        self.endedSecondsAgo = endedSecondsAgo
        self.isOpen = isOpen
        self.appName = appName
    }
}
