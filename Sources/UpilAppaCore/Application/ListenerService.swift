import Foundation

// MARK: - CONTRACT: ListenerService
//
// GUARANTEES:
// - dump allowed whenever ring has PCM (including after opportunistic capture stops).
// - dump(minutes:) writes via DumpSink after WavPCMEncoder; never writes when ring empty.
// - stopCapture idempotent.
// - startCapture when already listening → no-op success.
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

public enum ListenerError: Error, Equatable, Sendable {
    case notListening
    case emptyBuffer

    public var message: String {
        switch self {
        case .notListening:
            return "not listening"
        case .emptyBuffer:
            return "ring buffer is empty"
        }
    }
}

/// Daemon use cases: capture lifecycle and ring dump to WAV.
public final class ListenerService {
    private let capture: AudioCapturing
    private let dumpSink: DumpSink
    private let session = RecordingSession()
    private let stateQueue = DispatchQueue(label: "ai.upil.appa.listener-service")
    private var listening = false

    public init(capture: AudioCapturing, dumpSink: DumpSink) {
        self.capture = capture
        self.dumpSink = dumpSink
    }

    public var isListening: Bool {
        stateQueue.sync { listening }
    }

    public var hasBufferedAudio: Bool {
        session.filledBytes > 0
    }

    public func startCapture() throws {
        try stateQueue.sync {
            guard !listening else { return }
            try capture.start { [weak self] data in
                self?.session.append(data)
            }
            listening = true
        }
    }

    public func stopCapture() {
        stateQueue.sync {
            guard listening else { return }
            capture.stop()
            listening = false
        }
    }

    public func dump(minutes: Int?) async throws -> URL {
        let pcm = session.snapshotForDump(minutes: minutes)
        guard !pcm.isEmpty else { throw ListenerError.emptyBuffer }

        let wav = WavPCMEncoder.encode(pcm: pcm)
        let url = dumpSink.nextURL()
        try dumpSink.write(wav: wav, to: url)
        return url
    }
}