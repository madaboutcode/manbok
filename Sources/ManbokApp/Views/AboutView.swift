import SwiftUI

/// The one window allowed to be charming: a spec-plate + dedication page for
/// the "Listening Post" instrument. Design language: tasks/mockups/option-e-listening-post.html.
struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    private var versionLabel: String {
        "v\(version)" + (build.isEmpty ? "" : " (\(build))")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 30)

            AboutGlyph()
                .padding(.bottom, 16)

            wordmark
                .padding(.bottom, 8)

            Text("always listening, never missing a word.")
                .font(.system(size: 12, weight: .medium))
                .italic()
                .foregroundStyle(Theme.creamDim)
                .padding(.bottom, 22)

            equipmentPlate
                .padding(.bottom, 14)

            MicroLabel(text: "MONO · 16 KHZ · 16-BIT PCM · RAM ONLY")
                .padding(.bottom, 22)

            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)

            Text(creditText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.creamFaint)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 264)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            Text("madaboutcode")
                .font(Theme.mono(9))
                .tracking(0.6)
                .foregroundStyle(Theme.creamFaint.opacity(0.7))

            Spacer().frame(height: 22)
        }
        .frame(width: 320)
        .fixedSize()
        .background(PanelBackgroundView().ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .windowThemed()
    }

    private var wordmark: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("manbok")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.cream)
            Text("만복")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.creamFaint.opacity(0.85))
        }
    }

    /// Hairline-boxed hardware model plate, like an etched spec label.
    private var equipmentPlate: some View {
        VStack(spacing: 4) {
            MicroLabel(text: "MANBOK BR-10 · RING BUFFER UNIT")
            Text(versionLabel)
                .font(Theme.mono(10, weight: .medium))
                .foregroundStyle(Theme.amber)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.bgWell)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.lineStrong, lineWidth: 1)
                )
        )
    }

    private var creditText: String {
        "Named for Jung Man-bok (정만복), the tireless wiretapper of " +
        "Crash Landing on You — this app listens the way he did: always, " +
        "and without missing a word."
    }
}

/// A quiet breathing-ring accent for the spec plate header — a smaller,
/// stiller sibling of EmptyStateView's ListenGlyph, re-created here rather
/// than imported since that type is private to its own file.
private struct AboutGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            breathRing(size: 74, opacity: 0.08, delay: 0.6)
            breathRing(size: 58, opacity: 0.16, delay: 0)
            core
        }
        .frame(width: 74, height: 74)
        .accessibilityHidden(true)
        .onAppear {
            if !reduceMotion { isBreathing = true }
        }
    }

    private func breathRing(size: CGFloat, opacity: Double, delay: Double) -> some View {
        Circle()
            .strokeBorder(Theme.amber.opacity(opacity), lineWidth: 1)
            .frame(width: size, height: size)
            .scaleEffect(reduceMotion ? 1.0 : (isBreathing ? 1.05 : 0.9))
            .opacity(reduceMotion ? 1.0 : (isBreathing ? 1.0 : 0.5))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 3).repeatForever(autoreverses: true).delay(delay),
                value: isBreathing
            )
    }

    private var core: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Theme.amber.opacity(0.22), Theme.amber.opacity(0.04)],
                    center: UnitPoint(x: 0.35, y: 0.3),
                    startRadius: 0, endRadius: 16
                )
            )
            .overlay(Circle().strokeBorder(Theme.amber.opacity(0.3), lineWidth: 1))
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: "ear")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.amber)
            )
    }
}
