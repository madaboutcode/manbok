import SwiftUI

/// A rounded, inset well backing a waveform Canvas — the "tape gauge" recess
/// look shared by both waveform views. See Theme.swift / option-e mockup `.wave-well`.
private struct WaveformWell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Theme.bgWell.shadow(.inner(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)))
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let isOpen: Bool

    /// Trailing bars (newest audio, highest indices) rendered hotter while live.
    private static let recentBarCount = 12

    var body: some View {
        ZStack {
            WaveformWell()
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let barWidth = size.width / CGFloat(peaks.count)
                let recentStart = peaks.count - Self.recentBarCount
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, CGFloat(peak) * size.height)
                    let x = CGFloat(index) * barWidth
                    let rect = CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: max(1, barWidth - 1),
                        height: height
                    )
                    let barColor: Color = isOpen
                        ? (index >= recentStart ? Theme.amberHot : Theme.amber)
                        : Theme.tapeGreenDim
                    context.fill(Path(rect), with: .color(barColor))
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .accessibilityHidden(true)
    }
}

struct PlaybackWaveformView: View {
    let peaks: [Float]
    let isOpen: Bool
    let fraction: Double
    let onSeek: (Double) -> Void

    /// Bars are inset from the well edge; seek must map through the same inset
    /// so a click lands on the fraction it visually points at.
    private static let barInset: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack {
                WaveformWell()
                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let barWidth = size.width / CGFloat(peaks.count)
                    let cursorIndex = Int(fraction * Double(peaks.count))
                    let unplayedColor: Color = isOpen ? Theme.amber : Theme.tapeGreenDim

                    for (index, peak) in peaks.enumerated() {
                        let height = max(1, CGFloat(peak) * size.height)
                        let x = CGFloat(index) * barWidth
                        let rect = CGRect(
                            x: x,
                            y: (size.height - height) / 2,
                            width: max(1, barWidth - 1),
                            height: height
                        )
                        let color = index <= cursorIndex ? Theme.creamFaint.opacity(0.55) : unplayedColor
                        context.fill(Path(rect), with: .color(color))
                    }

                    let cursorX = CGFloat(fraction) * size.width
                    let glowRect = CGRect(x: cursorX - 3, y: 0, width: 6, height: size.height)
                    context.fill(Path(glowRect), with: .color(Theme.amberGlow))
                    let cursorRect = CGRect(x: cursorX - 1, y: 0, width: 2, height: size.height)
                    context.fill(Path(cursorRect), with: .color(Theme.amberHot))
                }
                .padding(.horizontal, Self.barInset)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let barsWidth = max(1, geo.size.width - Self.barInset * 2)
                        let f = Double((value.location.x - Self.barInset) / barsWidth)
                        onSeek(min(max(f, 0), 1))
                    }
            )
        }
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .accessibilityHidden(true)
    }
}
