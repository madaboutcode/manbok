import SwiftUI
import ManbokCore
import ManbokPlatform

struct HeaderView: View {
    @EnvironmentObject private var orchestrator: CaptureOrchestrator
    @EnvironmentObject private var viewModel: PopoverViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("manbok")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                stateBadge
            }
            ringFillBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var stateBadge: some View {
        if orchestrator.micPermission == .denied {
            Label("Mic access needed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
        } else if orchestrator.anySessionOpen {
            HStack(spacing: 4) {
                PulsingDot(reduceMotion: reduceMotion)
                Text("Recording")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.red)
        } else {
            Text("Watching")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var ringFillBar: some View {
        VStack(alignment: .trailing, spacing: 4) {
            GeometryReader { geo in
                let fraction = viewModel.ringCapacity > 0
                    ? CGFloat(viewModel.ringFilled) / CGFloat(viewModel.ringCapacity)
                    : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 3)

                    Capsule()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: max(0, geo.size.width * fraction), height: 3)
                }
            }
            .frame(height: 3)

            Group {
                if viewModel.ringFilled == 0 {
                    Text("Ring empty")
                } else {
                    Text("\(formattedMinutes(viewModel.ringFilled)) / \(formattedMinutes(viewModel.ringCapacity))")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private func formattedMinutes(_ bytes: Int) -> String {
        let totalSeconds = Int((Double(bytes) / Double(AudioFormat.bytesPerMinute) * 60).rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct PulsingDot: View {
    let reduceMotion: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1.0 : (isPulsing ? 0.3 : 1.0))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                if !reduceMotion { isPulsing = true }
            }
    }
}
