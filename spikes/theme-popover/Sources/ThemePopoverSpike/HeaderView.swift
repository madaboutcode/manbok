import SwiftUI
import ManbokCore

/// Ported from Sources/ManbokApp/Views/HeaderView.swift. Production reads
/// `orchestrator`/`viewModel` via @EnvironmentObject; here the same values arrive as
/// plain init params so the view can render without CaptureOrchestrator/PopoverViewModel.
/// Ring fill/capacity stay in bytes (not seconds) and go through `AudioFormat.bytesPerMinute`,
/// same as production, so the "7:12 / 30:00" label formatting can't drift from the real
/// rounding/truncation behavior.
struct HeaderView: View {
    let micDenied: Bool
    let isRecording: Bool
    let spinning: Bool
    let ringFilledBytes: Int
    let ringCapacityBytes: Int
    let sessionCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                wordmark
                Spacer()
                stateBadge
            }
            TapeGaugeView(
                progress: ringProgress,
                label: ringLabel,
                spinning: spinning
            )
                .padding(.top, 12)
            MicroLabel(text: "Tape · Channels \(sessionCount)")
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
        if micDenied {
            Label("Mic access needed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.amberHot)
        } else if isRecording {
            statusPill(
                dot: AnyView(PulsingDot(color: Theme.amberHot)),
                text: "Recording",
                textColor: Theme.amberHot,
                background: Theme.amber.opacity(0.10),
                border: Theme.amber.opacity(0.25)
            )
        } else {
            statusPill(
                dot: AnyView(StandbyDot()),
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
        ringCapacityBytes > 0
            ? Double(ringFilledBytes) / Double(ringCapacityBytes)
            : 0
    }

    private var ringLabel: String {
        ringFilledBytes == 0
            ? "Ring empty"
            : "\(formattedMinutes(ringFilledBytes)) / \(formattedMinutes(ringCapacityBytes))"
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
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: Theme.amberGlow, radius: 6)
            .opacity(isPulsing ? 0.3 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

/// Standby lamp for the Watching state: a slow, faint breathe.
private struct StandbyDot: View {
    @State private var isBreathing = false

    var body: some View {
        Circle()
            .fill(Theme.creamFaint)
            .frame(width: 6, height: 6)
            .opacity(isBreathing ? 0.45 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
    }
}
