import Foundation

/// VAD-lite: adaptive noise floor + RMS threshold (pure Swift, no ML).
struct SpeechActivityDetector {
    let multiplier: Float
    let minRMSThreshold: Float
    let floorAlpha: Float

    private(set) var noiseFloor: Float = 80
    private var initialized = false

    init(multiplier: Float = 4.0, minRMSThreshold: Float = 350, floorAlpha: Float = 0.05) {
        self.multiplier = multiplier
        self.minRMSThreshold = minRMSThreshold
        self.floorAlpha = floorAlpha
    }

    struct FrameMetrics {
        let rms: Float
        let peak: Int32
        let threshold: Float
        let isSpeech: Bool
    }

    mutating func analyze(pcm: Data) -> FrameMetrics {
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

    static func rmsAndPeak(_ pcm: Data) -> (Float, Int32) {
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