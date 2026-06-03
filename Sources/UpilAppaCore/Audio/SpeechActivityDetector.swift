import Foundation

// MARK: - CONTRACT (SpeechActivityDetector)
//
// GUARANTEES
// - Pure Swift RMS/peak analysis on s16le PCM; adaptive noise floor, no ML.
// - Speech when RMS >= max(floor * multiplier, minRMSThreshold).
//
// DOES NOT
// - Import AVFoundation or touch the ring buffer.

/// VAD-lite for opportunistic stop timing and foreground metering.
public struct SpeechActivityDetector: Sendable {
    public let multiplier: Float
    public let minRMSThreshold: Float
    public let floorAlpha: Float

    public private(set) var noiseFloor: Float = 80
    private var initialized = false

    public init(multiplier: Float = 4.0, minRMSThreshold: Float = 350, floorAlpha: Float = 0.05) {
        self.multiplier = multiplier
        self.minRMSThreshold = minRMSThreshold
        self.floorAlpha = floorAlpha
    }

    public struct FrameMetrics: Sendable, Equatable {
        public let rms: Float
        public let peak: Int32
        public let threshold: Float
        public let isSpeech: Bool
    }

    public mutating func analyze(pcm: Data) -> FrameMetrics {
        let (rms, peak) = Self.rmsAndPeak(pcm)
        if !initialized {
            noiseFloor = max(rms, 40)
            initialized = true
        }

        let threshold = max(noiseFloor * multiplier, minRMSThreshold)
        let isSpeech = rms >= threshold

        if !isSpeech {
            noiseFloor = noiseFloor * (1 - floorAlpha) + rms * floorAlpha
        }

        return FrameMetrics(rms: rms, peak: peak, threshold: threshold, isSpeech: isSpeech)
    }

    public static func rmsAndPeak(_ pcm: Data) -> (Float, Int32) {
        guard pcm.count >= 2 else { return (0, 0) }
        let samples = pcm.count / 2
        var sumSquares: Float = 0
        var peak: Int32 = 0
        pcm.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<samples {
                let s = Int32(ptr[i])
                let a = abs(s)
                if a > peak { peak = a }
                let f = Float(s)
                sumSquares += f * f
            }
        }
        let rms = sqrt(sumSquares / Float(samples))
        return (rms, peak)
    }
}