import SwiftUI

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

struct PlaybackWaveformView: View {
    let peaks: [Float]
    let isOpen: Bool
    let fraction: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                let barWidth = size.width / CGFloat(peaks.count)
                let cursorIndex = Int(fraction * Double(peaks.count))
                let baseColor: Color = isOpen ? .red : Color.blue.opacity(0.8)

                for (index, peak) in peaks.enumerated() {
                    let height = max(1, CGFloat(peak) * size.height)
                    let x = CGFloat(index) * barWidth
                    let rect = CGRect(
                        x: x,
                        y: (size.height - height) / 2,
                        width: max(1, barWidth - 1),
                        height: height
                    )
                    let color = index <= cursorIndex ? baseColor : baseColor.opacity(0.25)
                    context.fill(Path(rect), with: .color(color))
                }

                let cursorX = CGFloat(fraction) * size.width
                let cursorRect = CGRect(x: cursorX - 1, y: 0, width: 2, height: size.height)
                context.fill(Path(cursorRect), with: .color(.accentColor))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let f = Double(value.location.x / geo.size.width)
                        onSeek(min(max(f, 0), 1))
                    }
            )
        }
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        .accessibilityHidden(true)
    }
}
