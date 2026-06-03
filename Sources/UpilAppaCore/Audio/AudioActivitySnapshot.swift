import Foundation

/// Latest speech-activity frame (read from any thread; optional terminal UI).
public struct AudioActivitySnapshot: Sendable, Equatable {
    public static let idle = AudioActivitySnapshot(
        rms: 0, peak: 0, threshold: 0, noiseFloor: 80, isSpeech: false,
        secondsSinceSpeech: .infinity, chunkCount: 0, isListening: false
    )

    public let rms: Float
    public let peak: Int32
    public let threshold: Float
    public let noiseFloor: Float
    public let isSpeech: Bool
    public let secondsSinceSpeech: TimeInterval
    public let chunkCount: Int
    public let isListening: Bool
}