import Foundation
import ManbokCore

/// Mirrors `SessionRegistry.SessionSnapshot` field-for-field (that production type's
/// memberwise init is internal to ManbokCore, so it can't be constructed from here).
/// Keeping the same field names lets the ported view code stay close to the original.
struct MockSession: Identifiable {
    let stableId: UInt64
    let bundleID: String
    let displayName: String
    let durationSeconds: TimeInterval
    let startedAt: Date
    let endedAt: Date?
    let isOpen: Bool
    let audioBytes: Int
    let peaks: [Float]

    var id: UInt64 { stableId }
}

/// Seeded PRNG port of the mockup's `mulberry32` (tasks/mockups/option-e-listening-post.html),
/// reused here only to make waveform bars look organic instead of random noise.
private struct SeededRandom {
    private var state: UInt32
    init(seed: UInt32) { self.state = seed }

    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        let t1 = (state ^ (state >> 15)) &* (state | 1)
        let inner = (t1 ^ (t1 >> 7)) &* (t1 | 61)
        let t2 = (t1 &+ inner) ^ t1
        return Double(t2 ^ (t2 >> 14)) / 4294967296.0
    }
}

enum MockWaveform {
    /// Layered sine + noise envelope peaks in 0...1, matching WaveformSampler's output shape.
    static func peaks(count: Int, seed: UInt32) -> [Float] {
        var rand = SeededRandom(seed: seed)
        var out: [Float] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let fi = Double(i)
            let envelope = 0.35 + 0.65 * abs(sin(fi * 0.35 + Double(seed)) * sin(fi * 0.09 + 1))
            let noise = rand.next()
            out.append(Float(min(1, 0.15 + envelope * 0.6 + noise * 0.25)))
        }
        return out
    }
}

enum MockScenario {
    /// Hero shot: a live recording plus a couple of finished sessions, one of which is
    /// mid-playback so the amber scrub cursor + transport row show up in the same frame.
    static func heroSessions(now: Date) -> [MockSession] {
        [
            MockSession(
                stableId: 3,
                bundleID: "us.zoom.xos",
                displayName: "Zoom",
                durationSeconds: 7 * 60 + 12,
                startedAt: now.addingTimeInterval(-(7 * 60 + 12)),
                endedAt: nil,
                isOpen: true,
                audioBytes: 0,
                peaks: MockWaveform.peaks(count: 56, seed: 7)
            ),
            MockSession(
                stableId: 2,
                bundleID: "com.apple.Safari",
                displayName: "Safari",
                durationSeconds: 6 * 60 + 2,
                startedAt: now.addingTimeInterval(-(64 * 60)),
                endedAt: now.addingTimeInterval(-(58 * 60)),
                isOpen: false,
                audioBytes: 0,
                peaks: MockWaveform.peaks(count: 56, seed: 11)
            ),
            MockSession(
                stableId: 1,
                bundleID: "com.apple.FaceTime",
                displayName: "FaceTime",
                durationSeconds: 17 * 60 + 20,
                startedAt: now.addingTimeInterval(-(96 * 60)),
                endedAt: now.addingTimeInterval(-(79 * 60)),
                isOpen: false,
                audioBytes: 0,
                peaks: MockWaveform.peaks(count: 56, seed: 3)
            ),
            MockSession(
                stableId: 0,
                bundleID: "com.example.whispertranscribe",
                displayName: "Dictation",
                durationSeconds: 2 * 60 + 47,
                startedAt: now.addingTimeInterval(-(130 * 60)),
                endedAt: now.addingTimeInterval(-(127 * 60 + 13)),
                isOpen: false,
                audioBytes: 0,
                peaks: MockWaveform.peaks(count: 56, seed: 19)
            ),
        ]
    }

    /// Ring buffer config for the hero shot: 30-minute ring, ~7:12 filled (matches
    /// the live Zoom session's elapsed time, as if it's the only audio since the ring
    /// was last empty). Expressed in bytes via AudioFormat.bytesPerMinute, same unit
    /// PopoverViewModel.ringFilled/ringCapacity use in production.
    static let heroRingCapacityBytes = 30 * AudioFormat.bytesPerMinute
    static let heroRingFilledBytes = Int((7.0 * 60 + 12) / 60.0 * Double(AudioFormat.bytesPerMinute))
}
