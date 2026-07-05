import SwiftUI

/// Port of the mockup's `mulberry32` seeded PRNG (tasks/mockups/option-e-listening-post.html)
/// so the bars are deterministic across runs, same as the HTML version.
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

enum WaveformGenerator {
    /// Layered sine + noise envelope, same shape as the mockup's `buildBars`.
    static func heights(count: Int, seed: UInt32) -> [Double] {
        var rand = SeededRandom(seed: seed)
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let fi = Double(i)
            let envelope = 0.35 + 0.65 * abs(sin(fi * 0.35 + Double(seed)) * sin(fi * 0.09 + 1))
            let noise = rand.next()
            out.append(min(1, 0.15 + envelope * 0.6 + noise * 0.25))
        }
        return out
    }
}

enum WaveformStyle {
    case idle
    case live(recentFrom: Int)
    case played(pastUntil: Int, playheadRatio: Double)
}

struct WaveformWellView: View {
    let heights: [Double]
    let style: WaveformStyle
    var height: CGFloat = 34

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.bgWell.shadow(.inner(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)))

            GeometryReader { geo in
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(heights.indices, id: \.self) { i in
                        Capsule()
                            .fill(barColor(for: i))
                            .frame(height: max(2, heights[i] * (height - 8)))
                            .shadow(color: barGlow(for: i), radius: 3)
                    }
                }
                .padding(.horizontal, 6)
                .frame(width: geo.size.width, height: height, alignment: .center)

                if case .played(_, let ratio) = style {
                    Rectangle()
                        .fill(Theme.amberHot)
                        .frame(width: 2, height: height - 6)
                        .shadow(color: Theme.amberGlow, radius: 5)
                        .position(x: geo.size.width * ratio, y: height / 2)
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func barColor(for i: Int) -> Color {
        switch style {
        case .idle:
            return Theme.tapeGreenDim.opacity(0.85)
        case .live(let recentFrom):
            return i >= recentFrom ? Theme.amberHot : Theme.amber.opacity(0.85)
        case .played(let pastUntil, _):
            return i < pastUntil ? Theme.creamFaint.opacity(0.55) : Theme.tapeGreenDim.opacity(0.85)
        }
    }

    private func barGlow(for i: Int) -> Color {
        switch style {
        case .live:
            return Theme.amber.opacity(0.3)
        default:
            return .clear
        }
    }
}
