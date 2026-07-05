import SwiftUI

/// Scene 2: MenuBarExtra content. Compact themed content (header + one live row + footer)
/// to probe whether the dark panel reaches the popover's rounded corners without
/// system material fringing, and whether repeatForever animations keep running
/// across popover close/reopen.
struct MenuBarProbeView: View {
    private let safariHeights = WaveformGenerator.heights(count: 60, seed: 7)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    WordmarkView()
                    Spacer()
                    StatusPillView(label: "Recording", recording: true)
                }
                TapeGaugeView(progress: 0.853, label: "8:32 / 10:00", spinning: true)
                    .padding(.top, 12)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)

            VStack(spacing: 2) {
                SessionRowView(
                    icon: AppIconBadge(letter: "S", gradient: [Color(hex: 0x79C2E0), Color(hex: 0x3B8FBF)], textColor: .white),
                    name: "Safari",
                    timeRange: "2:41 PM \u{2013}",
                    duration: "3m 12s",
                    kind: .live,
                    waveformHeights: safariHeights,
                    waveformStyle: .live(recentFrom: 48)
                )
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))

            PopoverFooterView()
        }
        .frame(width: 300)
        .background(PanelBackground())
    }
}
