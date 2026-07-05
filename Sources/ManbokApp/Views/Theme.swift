import SwiftUI

/// Listening Post theme — design source of truth: tasks/mockups/option-e-listening-post.html.
/// Lamp-lit warm dark: tungsten amber for live audio, phosphor tape-green for idle,
/// cream text hierarchy. All timestamps/durations/counters use `Theme.mono`.
enum Theme {
    // MARK: Surfaces
    static let bgPanel = Color(hex: 0x1B1611)
    static let bgPanelTop = Color(hex: 0x1F1A14)
    static let bgWell = Color(hex: 0x14100C)

    // MARK: Hairlines
    private static let lineBase = Color(hex: 0xD6B684)
    static let line = lineBase.opacity(0.10)
    static let lineStrong = lineBase.opacity(0.16)

    // MARK: Text
    static let cream = Color(hex: 0xF1E6D3)
    static let creamDim = Color(hex: 0xCBB99E)
    static let creamFaint = Color(hex: 0x8D7D68)

    // MARK: Accents
    static let amber = Color(hex: 0xE0A951)
    static let amberHot = Color(hex: 0xFFB84D)
    static let amberGlow = Color(hex: 0xE0A951, opacity: 0.35)
    static let tapeGreen = Color(hex: 0x8FBF7A)
    static let tapeGreenDim = Color(hex: 0x5D7A53)
    static let danger = Color(hex: 0xC96A4F)

    // MARK: Fonts
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Panel background

/// The popover's lamp-lit shell: vertical panel gradient, a faint tungsten
/// glow bleeding in from the top, and a soft edge vignette. The hosting
/// MenuBarExtra window supplies the rounded corners; apply full-bleed via
/// `.background(PanelBackgroundView().ignoresSafeArea())`.
struct PanelBackgroundView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.bgPanelTop, Theme.bgPanel],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Theme.amber.opacity(0.07), .clear],
                center: UnitPoint(x: 0.5, y: -0.05),
                startRadius: 0, endRadius: 180
            )
            RadialGradient(
                colors: [.clear, .black.opacity(0.28)],
                center: .center,
                startRadius: 90, endRadius: 260
            )
        }
    }
}

// MARK: - Tape gauge

/// Reel + tape track + counter. The reel's spoke holes make rotation visible;
/// it turns only while `spinning` and stops under Reduce Motion. Callers format
/// the counter text (see HeaderView.formattedMinutes).
struct TapeGaugeView: View {
    /// Ring fill, 0...1.
    let progress: Double
    /// Monospace counter, e.g. "8:32 / 10:00".
    let label: String
    /// True while audio is being captured.
    let spinning: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let secondsPerRevolution: Double = 6

    var body: some View {
        HStack(spacing: 10) {
            reel
            track
            Text(label)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.creamDim)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ring buffer \(label)")
    }

    private var reel: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning || reduceMotion)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / Self.secondsPerRevolution
            ReelShape()
                .rotationEffect(.degrees(spinning ? turns.truncatingRemainder(dividingBy: 1) * 360 : 0))
        }
        .frame(width: 20, height: 20)
        .foregroundStyle(spinning ? Theme.amber : Theme.creamFaint.opacity(0.5))
        .background(
            Circle().fill(
                RadialGradient(
                    colors: [Theme.amber.opacity(spinning ? 0.10 : 0.04), .clear],
                    center: .center, startRadius: 0, endRadius: 10
                )
            )
        )
    }

    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.bgWell.shadow(.inner(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.tapeGreenDim, Theme.tapeGreen],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * min(max(progress, 0), 1)))
                    .shadow(color: Theme.tapeGreen.opacity(0.35), radius: 6)
            }
        }
        .frame(height: 5)
    }
}

/// A tape reel: rim, center hub, and three spoke holes so rotation reads.
private struct ReelShape: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: 2).opacity(0.45)
            Circle().frame(width: 4, height: 4)
            ForEach(0..<3, id: \.self) { spoke in
                Circle()
                    .frame(width: 2.5, height: 2.5)
                    .offset(y: -5.5)
                    .rotationEffect(.degrees(Double(spoke) * 120))
                    .opacity(0.8)
            }
        }
    }
}

// MARK: - Micro label

/// Uppercase tracked-out instrument-panel caption, e.g. "TAPE · CHANNELS 3".
struct MicroLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9))
            .tracking(1.2)
            .foregroundStyle(Theme.creamFaint)
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
