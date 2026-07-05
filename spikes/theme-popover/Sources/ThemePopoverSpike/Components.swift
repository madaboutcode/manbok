import SwiftUI

// MARK: - Panel chrome (the popover's dark lamp-lit shell)

struct PanelBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgPanelTop, Theme.bgPanel], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Theme.amber.opacity(0.07), .clear],
                center: UnitPoint(x: 0.5, y: -0.05),
                startRadius: 0,
                endRadius: 180
            )
        }
    }
}

struct PanelContainer<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: width)
            .background(PanelBackground())
            .overlay(
                // vignette approximation: inner shadow via the .shadow(.inner) ShapeStyle modifier
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.001).shadow(.inner(color: .black.opacity(0.5), radius: 30, x: 0, y: 10)))
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.lineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 12)
    }
}

// MARK: - Header

struct WordmarkView: View {
    var body: some View {
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
}

struct StatusPillView: View {
    let label: String
    let recording: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(recording ? Theme.amberHot : Theme.creamFaint)
                .frame(width: 6, height: 6)
                .shadow(color: recording ? Theme.amberGlow : .clear, radius: 6)
                .opacity(recording ? (pulse ? 0.35 : 1) : 1)
                .scaleEffect(recording ? (pulse ? 0.8 : 1) : 1)
                .onAppear {
                    guard recording else { return }
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(recording ? Theme.amberHot : Theme.creamFaint)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(recording ? Theme.amber.opacity(0.10) : Color.white.opacity(0.03))
        )
        .overlay(
            Capsule().strokeBorder(recording ? Theme.amber.opacity(0.25) : Theme.lineStrong, lineWidth: 1)
        )
    }
}

struct TapeGaugeView: View {
    /// 0...1
    let progress: Double
    let label: String
    let spinning: Bool
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(spinning ? Theme.amber.opacity(0.4) : Theme.creamFaint.opacity(0.22), lineWidth: 2)
                    .background(
                        Circle().fill(
                            RadialGradient(colors: [Theme.amber.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 10)
                        )
                    )
                Circle()
                    .fill(spinning ? Theme.amber.opacity(0.85) : Theme.creamFaint.opacity(0.5))
                    .padding(6)
            }
            .frame(width: 20, height: 20)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                guard spinning else { return }
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.bgWell.shadow(.inner(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.tapeGreenDim, Theme.tapeGreen], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progress)
                        .shadow(color: Theme.tapeGreen.opacity(0.35), radius: 6)
                }
            }
            .frame(height: 5)

            Text(label)
                .font(.mono(10))
                .foregroundStyle(Theme.creamDim)
                .fixedSize()
        }
    }
}

struct MicroLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .regular))
            .tracking(1.2)
            .foregroundStyle(Theme.creamFaint)
    }
}

// MARK: - Footer

struct PopoverFooterView: View {
    var body: some View {
        HStack {
            Text("About")
                .font(.system(size: 11))
                .foregroundStyle(Theme.creamDim)
            Spacer()
            Text("Settings\u{2026}")
                .font(.system(size: 11))
                .foregroundStyle(Theme.creamDim)
            Spacer()
            Text("Quit")
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }
}
