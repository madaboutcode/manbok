import Foundation

// MARK: - CONTRACT: ListenerService
//
// GUARANTEES:
// - closeSession() finalizes the current recording session as metadata (no bytes written to ring).
// - dump allowed whenever ring has PCM (ring not cleared on stopCapture).
// - dump(minutes:) writes via DumpSink after WavPCMEncoder; never writes when ring empty.
// - stopCapture idempotent.
// - startCapture when already listening → no-op success.
// - listSessions()/dump(sessionId:) use SessionRegistry's stable UInt64 ids directly, newest-first
//   (see docs/specs/interfaces/ipc.md §2.3, §4).
//
// EXPECTS:
// - AudioCapturing and DumpSink injected at construction.
//
// FAILURE BEHAVIOR:
// - capture start throws propagate; listening flag unchanged on failure.
// - dump disk errors propagate from DumpSink.write.
//
// DOES NOT:
// - Parse CLI flags, launch GUI apps, or import platform frameworks.
// - embed gap markers in the ring.

public enum ListenerError: Error, Equatable, Sendable {
    case notListening
    case emptyBuffer
    case sessionNotFound(UInt64)

    public var message: String {
        switch self {
        case .notListening:
            return "not listening"
        case .emptyBuffer:
            return "ring buffer is empty"
        case .sessionNotFound(let id):
            return "session \(id) not found"
        }
    }

    /// Stable IPC error code (see docs/specs/interfaces/ipc.md §3).
    public var code: String {
        switch self {
        case .notListening: return "not_listening"
        case .emptyBuffer: return "empty_buffer"
        case .sessionNotFound: return "session_not_found"
        }
    }
}

/// Daemon use cases: capture lifecycle and ring dump to WAV.
public final class ListenerService {
    private let capture: AudioCapturing
    private let dumpSink: DumpSink
    private let registry = SessionRegistry()
    private let stateQueue = DispatchQueue(label: "ai.manbok.app.listener-service")
    private var listening = false
    private var speechDetector = SpeechActivityDetector()
    private var lastSpeechAt: Date?
    /// Last frame at or above VAD threshold (used when speech was never flagged).
    private var lastActiveAt: Date?
    private var lastAppendAt: Date?
    private var chunkCount = 0
    private var activitySnapshot = AudioActivitySnapshot.idle

    /// Transitional shim: SessionRegistry is keyed per-app bundleID, but
    /// OpportunisticCaptureController (pre-Phase-2) still drives a single continuous "union"
    /// session through setSessionAppName/closeSession with no bundleID at all. This fixed key
    /// stands in for that one session. Remove once CaptureOrchestrator (Phase 2 task 2.1) calls
    /// SessionRegistry directly with real per-app bundle ids.
    private let legacyBundleID = "ai.manbok.app.legacy-session"
    private var legacySessionIsOpen = false
    private var legacyPendingDisplayName = ""

    public init(capture: AudioCapturing, dumpSink: DumpSink) {
        self.capture = capture
        self.dumpSink = dumpSink
    }

    public var isListening: Bool {
        stateQueue.sync { listening }
    }

    public var hasBufferedAudio: Bool {
        ringFilledBytes > 0
    }

    /// PCM bytes currently in the ring (preserved across stopCapture / watching).
    public var ringFilledBytes: Int {
        registry.filledBytes
    }

    /// Time since last audio chunk was appended to the ring.
    public var secondsSinceLastAudio: TimeInterval {
        stateQueue.sync {
            guard let lastAppendAt else { return .infinity }
            return Date().timeIntervalSince(lastAppendAt)
        }
    }

    /// Time since last speech frame (VAD-lite); `.infinity` if none yet this session.
    public var secondsSinceLastSpeech: TimeInterval {
        stateQueue.sync {
            guard let lastSpeechAt else { return .infinity }
            return Date().timeIntervalSince(lastSpeechAt)
        }
    }

    /// Time since last frame at/above VAD threshold; `.infinity` if none yet this session.
    public var secondsSinceLastActiveAudio: TimeInterval {
        stateQueue.sync {
            guard let lastActiveAt else { return .infinity }
            return Date().timeIntervalSince(lastActiveAt)
        }
    }

    public var captureChunkCount: Int {
        stateQueue.sync { chunkCount }
    }

    /// Latest activity snapshot (thread-safe; terminal presenter may poll).
    public var currentActivity: AudioActivitySnapshot {
        stateQueue.sync { activitySnapshot }
    }

    public func startCapture() throws {
        let shouldStart = stateQueue.sync { () -> Bool in
            guard !listening else { return false }
            speechDetector = SpeechActivityDetector()
            lastSpeechAt = nil
            lastActiveAt = nil
            chunkCount = 0
            activitySnapshot = AudioActivitySnapshot.idle
            listening = true
            refreshActivitySnapshot(isListening: true)
            return true
        }
        guard shouldStart else { return }

        do {
            try capture.start { [self] data in
                ingestPCM(data)
            }
        } catch {
            stateQueue.sync {
                listening = false
                refreshActivitySnapshot(isListening: false)
            }
            throw error
        }
    }

    /// Finalizes the current recording session as metadata (no bytes written to ring).
    public func closeSession(appName: String? = nil) {
        stateQueue.sync {
            if let appName { legacyPendingDisplayName = appName }
            legacySessionIsOpen = false
            legacyPendingDisplayName = ""
        }
        if let appName {
            registry.setDisplayName(bundleID: legacyBundleID, displayName: appName)
        }
        registry.closeSession(bundleID: legacyBundleID)
    }

    /// Sets the app name for the currently open session.
    public func setSessionAppName(_ name: String?) {
        guard let name else { return }
        stateQueue.sync { legacyPendingDisplayName = name }
        registry.setDisplayName(bundleID: legacyBundleID, displayName: name)
    }

    public func stopCapture() {
        let shouldStop = stateQueue.sync { () -> Bool in
            guard listening else { return false }
            listening = false
            return true
        }
        guard shouldStop else { return }

        capture.stop()
        stateQueue.sync {
            speechDetector = SpeechActivityDetector()
            lastSpeechAt = nil
            lastActiveAt = nil
            refreshActivitySnapshot(isListening: false)
        }
    }

    private func ingestPCM(_ data: Data) {
        stateQueue.sync {
            guard listening else { return }
            lastAppendAt = Date()
            if !legacySessionIsOpen {
                registry.openSession(bundleID: legacyBundleID, displayName: legacyPendingDisplayName)
                legacySessionIsOpen = true
            }
            registry.append(data)
            chunkCount += 1
            var detector = speechDetector
            let metrics = detector.analyze(pcm: data)
            speechDetector = detector
            let now = Date()
            if metrics.isSpeech {
                lastSpeechAt = now
            }
            if metrics.rms >= metrics.threshold {
                lastActiveAt = now
            }
            let quiet = lastSpeechAt.map { now.timeIntervalSince($0) } ?? .infinity
            activitySnapshot = AudioActivitySnapshot(
                rms: metrics.rms,
                peak: metrics.peak,
                threshold: metrics.threshold,
                noiseFloor: speechDetector.noiseFloor,
                isSpeech: metrics.isSpeech,
                secondsSinceSpeech: quiet,
                chunkCount: chunkCount,
                isListening: listening
            )
        }
    }

    private func refreshActivitySnapshot(isListening: Bool) {
        let quiet = lastSpeechAt.map { Date().timeIntervalSince($0) } ?? .infinity
        activitySnapshot = AudioActivitySnapshot(
            rms: activitySnapshot.rms,
            peak: activitySnapshot.peak,
            threshold: activitySnapshot.threshold,
            noiseFloor: speechDetector.noiseFloor,
            isSpeech: activitySnapshot.isSpeech,
            secondsSinceSpeech: quiet,
            chunkCount: chunkCount,
            isListening: isListening
        )
    }

    /// Newest-first session list, stable ids passed straight through from SessionRegistry.
    public func listSessions() -> [SessionSummary] {
        let now = Date()
        return registry.listSessions().map { snapshot in
            SessionSummary(
                id: snapshot.stableId,
                audioBytes: snapshot.audioBytes,
                durationSeconds: snapshot.durationSeconds,
                startedSecondsAgo: now.timeIntervalSince(snapshot.startedAt),
                endedSecondsAgo: snapshot.endedAt.map { now.timeIntervalSince($0) },
                isOpen: snapshot.isOpen,
                appName: snapshot.displayName.isEmpty ? nil : snapshot.displayName
            )
        }
    }

    public func dump(minutes: Int?) async throws -> URL {
        let pcm = registry.snapshotForDump(minutes: minutes)
        guard !pcm.isEmpty else { throw ListenerError.emptyBuffer }
        return try writeWAV(pcm: pcm)
    }

    public func dump(sessionId: UInt64) async throws -> URL {
        guard let pcm = registry.snapshotForSession(stableId: sessionId), !pcm.isEmpty else {
            throw ListenerError.sessionNotFound(sessionId)
        }
        return try writeWAV(pcm: pcm)
    }

    private func writeWAV(pcm: Data) throws -> URL {
        let wav = WavPCMEncoder.encode(pcm: pcm)
        let url = dumpSink.nextURL()
        try dumpSink.write(wav: wav, to: url)
        return url
    }
}