import SwiftUI

struct AppIconBadge: View {
    let letter: String
    let gradient: [Color]
    let textColor: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 28, height: 28)
            .overlay(
                Text(letter)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(textColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    .blendMode(.plusLighter)
            )
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
    }
}

struct IconButton: View {
    let systemName: String
    var tintedAmber: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(0.02))
            .frame(width: 21, height: 21)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 9))
                    .foregroundStyle(tintedAmber ? Theme.amber : Theme.creamDim)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tintedAmber ? Theme.amber.opacity(0.3) : Theme.lineStrong, lineWidth: 1)
            )
    }
}

enum SessionRowKind {
    case idle(actions: Bool)
    case live
    case played(transport: String)
}

struct SessionRowView: View {
    let icon: AppIconBadge
    let name: String
    let timeRange: String
    let duration: String
    let kind: SessionRowKind
    let waveformHeights: [Double]
    let waveformStyle: WaveformStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        HStack(spacing: 5) {
                            Text(name)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(Theme.cream)
                            if case .live = kind {
                                Text("LIVE")
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(Theme.amberHot)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.amber.opacity(0.14)))
                            }
                        }
                        Spacer()
                        Text(timeRange)
                            .font(.mono(10.5))
                            .foregroundStyle(Theme.creamDim)
                    }
                    Text(duration)
                        .font(.mono(10))
                        .foregroundStyle(Theme.creamFaint)
                }

                if case .idle(let hasActions) = kind, hasActions {
                    HStack(spacing: 5) {
                        IconButton(systemName: "play.fill", tintedAmber: true)
                        IconButton(systemName: "arrow.down.circle")
                        IconButton(systemName: "doc.on.doc")
                    }
                }
                if case .played = kind {
                    HStack(spacing: 5) {
                        IconButton(systemName: "pause.fill", tintedAmber: true)
                        IconButton(systemName: "arrow.down.circle")
                        IconButton(systemName: "doc.on.doc")
                    }
                }
            }

            WaveformWellView(heights: waveformHeights, style: waveformStyle)

            if case .played(let transport) = kind {
                Text(transport)
                    .font(.mono(10))
                    .foregroundStyle(Theme.amberHot)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isLive ? Theme.amber.opacity(0.22) : .clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var isLive: Bool {
        if case .live = kind { return true }
        return false
    }

    @ViewBuilder private var rowBackground: some View {
        if isLive {
            LinearGradient(colors: [Theme.amber.opacity(0.09), Theme.amber.opacity(0.03)], startPoint: .top, endPoint: .bottom)
        } else {
            Color.clear
        }
    }
}
