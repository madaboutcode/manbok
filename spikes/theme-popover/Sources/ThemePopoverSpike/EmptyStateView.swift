import SwiftUI

struct BreathingRing: View {
    let inset: CGFloat
    let opacity: Double
    let delay: Double
    @State private var animate = false

    var body: some View {
        Circle()
            .strokeBorder(Theme.amber.opacity(opacity), lineWidth: 1)
            .padding(-inset)
            .scaleEffect(animate ? 1.05 : 0.9)
            .opacity(animate ? 1 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true).delay(delay)) {
                    animate = true
                }
            }
    }
}

struct ListenGlyphView: View {
    var body: some View {
        ZStack {
            BreathingRing(inset: 20, opacity: 0.07, delay: 1.2)
            BreathingRing(inset: 10, opacity: 0.14, delay: 0.6)
            BreathingRing(inset: 0, opacity: 0.25, delay: 0)
            Circle()
                .fill(RadialGradient(colors: [Theme.amber.opacity(0.22), Theme.amber.opacity(0.04)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 20))
                .overlay(Circle().strokeBorder(Theme.amber.opacity(0.3), lineWidth: 1))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "ear")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.amber)
                )
        }
        .frame(width: 68, height: 68)
    }
}

/// Mirrors the "narrow" empty-state popover in the mockup.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    WordmarkView()
                    Spacer()
                    StatusPillView(label: "Idle", recording: false)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)

            VStack(spacing: 0) {
                ListenGlyphView()
                    .padding(.bottom, 18)
                Text("Listening\u{2026}")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.cream)
                Text("When an app uses your mic, manbok will keep the audio here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.creamFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 210)
                    .padding(.top, 6)
                TapeGaugeView(progress: 0, label: "0:00 / 10:00", spinning: false)
                    .padding(.top, 20)
            }
            .padding(EdgeInsets(top: 44, leading: 20, bottom: 34, trailing: 20))

            PopoverFooterView()
        }
    }
}
