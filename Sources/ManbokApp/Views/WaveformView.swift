import SwiftUI

/// Decorative bar-waveform for a session's peak samples. No animation is ever applied here —
/// refreshes are discrete (driven by polling), so Reduce Motion needs no special-casing.
struct WaveformView: View {
    let peaks: [Float]
    let isOpen: Bool

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let barColor: Color = isOpen ? .red : Color.blue.opacity(0.6)
            let barWidth = size.width / CGFloat(peaks.count)
            for (index, peak) in peaks.enumerated() {
                let height = max(1, CGFloat(peak) * size.height)
                let x = CGFloat(index) * barWidth
                let rect = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: max(1, barWidth - 1),
                    height: height
                )
                context.fill(Path(rect), with: .color(barColor))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        .accessibilityHidden(true)
    }
}
