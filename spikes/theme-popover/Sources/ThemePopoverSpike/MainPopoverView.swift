import SwiftUI

/// Mirrors the "wide" popover in the mockup: recording state, tape gauge, three session rows.
struct MainPopoverView: View {
    private let zoomHeights = WaveformGenerator.heights(count: 60, seed: 3)
    private let safariHeights = WaveformGenerator.heights(count: 60, seed: 7)
    private let qtHeights = WaveformGenerator.heights(count: 60, seed: 11)

    private var qtPlayedRatio: Double { (2 * 60 + 47) / Double(6 * 60 + 2) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    WordmarkView()
                    Spacer()
                    StatusPillView(label: "Recording", recording: true)
                }
                TapeGaugeView(progress: 0.853, label: "8:32 / 10:00", spinning: true)
                    .padding(.top, 12)
                MicroLabel(text: "TAPE  \u{00B7}  CHANNELS 3")
                    .padding(.top, 8)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
            .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)

            // Session list
            VStack(spacing: 2) {
                SessionRowView(
                    icon: AppIconBadge(letter: "Z", gradient: [Color(hex: 0x8FB3E8), Color(hex: 0x5B87C9)], textColor: .white),
                    name: "Zoom",
                    timeRange: "2:14\u{2013}2:36 PM",
                    duration: "21m 43s",
                    kind: .idle(actions: true),
                    waveformHeights: zoomHeights,
                    waveformStyle: .idle
                )
                Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 4)

                SessionRowView(
                    icon: AppIconBadge(letter: "S", gradient: [Color(hex: 0x79C2E0), Color(hex: 0x3B8FBF)], textColor: .white),
                    name: "Safari",
                    timeRange: "2:41 PM \u{2013}",
                    duration: "3m 12s",
                    kind: .live,
                    waveformHeights: safariHeights,
                    waveformStyle: .live(recentFrom: 48)
                )
                Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 4)

                SessionRowView(
                    icon: AppIconBadge(letter: "Q", gradient: [Color(hex: 0xD9C48F), Color(hex: 0xB99552)], textColor: Theme.bgRoom),
                    name: "QuickTime Player",
                    timeRange: "1:02\u{2013}1:08 PM",
                    duration: "6m 2s",
                    kind: .played(transport: "2:47 / 6:02"),
                    waveformHeights: qtHeights,
                    waveformStyle: .played(pastUntil: Int(60 * qtPlayedRatio), playheadRatio: qtPlayedRatio)
                )
            }
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))

            PopoverFooterView()
        }
    }
}
