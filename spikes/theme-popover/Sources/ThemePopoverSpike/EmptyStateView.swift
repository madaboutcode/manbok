import SwiftUI
import ManbokCore

/// Ported from Sources/ManbokApp/Views/EmptyStateView.swift. Production reads ring
/// fill/capacity from PopoverViewModel via @EnvironmentObject; here they're plain params.
/// Bytes + AudioFormat.bytesPerMinute, same as production (see HeaderView.swift's note).
struct EmptyStateView: View {
    let ringFilledBytes: Int
    let ringCapacityBytes: Int

    var body: some View {
        VStack(spacing: 0) {
            ListenGlyph()
                .padding(.bottom, 18)

            Text("Listening…")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.cream)

            Text("When an app uses your mic, manbok will keep the audio here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.creamFaint)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 210)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            TapeGaugeView(progress: ringProgress, label: ringLabel, spinning: false)
                .padding(.top, 20)
        }
        .padding(.top, 44)
        .padding(.horizontal, 20)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ringProgress: Double {
        ringCapacityBytes > 0
            ? Double(ringFilledBytes) / Double(ringCapacityBytes)
            : 0
    }

    private var ringLabel: String {
        "\(formattedMinutes(ringFilledBytes)) / \(formattedMinutes(ringCapacityBytes))"
    }

    private func formattedMinutes(_ bytes: Int) -> String {
        let totalSeconds = Int((Double(bytes) / Double(AudioFormat.bytesPerMinute) * 60).rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Three concentric breathing rings around a lamp-lit core — the theme's hero glyph.
private struct ListenGlyph: View {
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            breathRing(size: 108, opacity: 0.07, delay: 1.2)
            breathRing(size: 88, opacity: 0.14, delay: 0.6)
            breathRing(size: 68, opacity: 0.25, delay: 0)
            core
        }
        .frame(width: 108, height: 108)
        .accessibilityHidden(true)
        .onAppear { isBreathing = true }
    }

    private func breathRing(size: CGFloat, opacity: Double, delay: Double) -> some View {
        Circle()
            .strokeBorder(Theme.amber.opacity(opacity), lineWidth: 1)
            .frame(width: size, height: size)
            .scaleEffect(isBreathing ? 1.05 : 0.9)
            .opacity(isBreathing ? 1.0 : 0.4)
            .animation(
                .easeInOut(duration: 3).repeatForever(autoreverses: true).delay(delay),
                value: isBreathing
            )
    }

    private var core: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Theme.amber.opacity(0.22), Theme.amber.opacity(0.04)],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 0, endRadius: 20
                )
            )
            .overlay(Circle().strokeBorder(Theme.amber.opacity(0.3), lineWidth: 1))
            .frame(width: 36, height: 36)
            .overlay(
                Image(systemName: "ear")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.amber)
            )
    }
}
