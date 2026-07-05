import SwiftUI
import ManbokCore
import ManbokPlatform

struct HeaderView: View {
    @EnvironmentObject private var orchestrator: CaptureOrchestrator
    @EnvironmentObject private var viewModel: PopoverViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                wordmark
                Spacer()
                stateBadge
            }
            // Tape moves whenever audio moves: capturing new audio or replaying it.
            TapeGaugeView(
                progress: ringProgress,
                label: ringLabel,
                spinning: orchestrator.anySessionOpen || viewModel.playback.isPlaying
            )
                .padding(.top, 12)
            MicroLabel(text: "Tape · Channels \(viewModel.sessions.count)")
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var wordmark: some View {
        HStack(alignment: .lastTextBaseline, spacing: 7) {
            Text("manbok")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.cream)
            Text("만복")
                .font(.system(size: 10))
                .foregroundStyle(Theme.creamFaint)
                .opacity(0.7)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        if orchestrator.micPermission == .denied {
            Label("Mic access needed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.amberHot)
        } else if orchestrator.anySessionOpen {
            statusPill(
                dot: AnyView(PulsingDot(color: Theme.amberHot, reduceMotion: reduceMotion)),
                text: "Recording",
                textColor: Theme.amberHot,
                background: Theme.amber.opacity(0.10),
                border: Theme.amber.opacity(0.25)
            )
        } else {
            statusPill(
                dot: AnyView(StandbyDot(reduceMotion: reduceMotion)),
                text: "Watching",
                textColor: Theme.creamFaint,
                background: Color.white.opacity(0.03),
                border: Theme.lineStrong
            )
        }
    }

    private func statusPill(dot: AnyView, text: String, textColor: Color, background: Color, border: Color) -> some View {
        HStack(spacing: 6) {
            dot
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textColor)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(background)
                .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        )
    }

    private var ringProgress: Double {
        viewModel.ringCapacity > 0
            ? Double(viewModel.ringFilled) / Double(viewModel.ringCapacity)
            : 0
    }

    private var ringLabel: String {
        viewModel.ringFilled == 0
            ? "Ring empty"
            : "\(formattedMinutes(viewModel.ringFilled)) / \(formattedMinutes(viewModel.ringCapacity))"
    }

    private func formattedMinutes(_ bytes: Int) -> String {
        let totalSeconds = Int((Double(bytes) / Double(AudioFormat.bytesPerMinute) * 60).rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct PulsingDot: View {
    let color: Color
    let reduceMotion: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: Theme.amberGlow, radius: 6)
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

/// Standby lamp for the Watching state: a slow, faint breathe — the ear is
/// open, nothing is being taped. Deliberately quieter than PulsingDot.
private struct StandbyDot: View {
    let reduceMotion: Bool
    @State private var isBreathing = false

    var body: some View {
        Circle()
            .fill(Theme.creamFaint)
            .frame(width: 6, height: 6)
            .opacity(reduceMotion ? 1.0 : (isBreathing ? 0.45 : 1.0))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 4.5).repeatForever(autoreverses: true),
                value: isBreathing
            )
            .onAppear {
                if !reduceMotion { isBreathing = true }
            }
    }
}
