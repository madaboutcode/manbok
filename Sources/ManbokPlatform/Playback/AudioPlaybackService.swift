import AVFoundation
import Combine

@MainActor
public final class AudioPlaybackService: NSObject, ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    public func play(wavData: Data) throws {
        stop()
        let p = try AVAudioPlayer(data: wavData)
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = 0
        p.play()
        isPlaying = true
        startProgressTimer()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func resume() {
        player?.play()
        isPlaying = true
        startProgressTimer()
    }

    public func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    public func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = clamped * duration
        currentTime = player.currentTime
    }

    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }
}

extension AudioPlaybackService: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil
            self?.currentTime = self?.duration ?? 0
        }
    }
}
