import Foundation

/// One captured session slice in the ring (1-based id assigned at list time).
public struct SessionSummary: Sendable, Equatable {
    public let id: Int
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
        id: Int,
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
