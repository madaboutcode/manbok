import SwiftUI

/// Interactive dev window: all three popover states side by side, MOCK data — same
/// PopoverContentView the offscreen renderer uses (ScreenshotRenderer.swift), so what
/// you see here is what ends up in the PNGs.
struct VibeCheckView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            labeled("Sessions — hero shot") {
                PopoverContentView(state: .sessions(
                    MockScenario.heroSessions(now: Date()),
                    isRecording: true,
                    ringFilledBytes: MockScenario.heroRingFilledBytes,
                    ringCapacityBytes: MockScenario.heroRingCapacityBytes
                ))
            }
            labeled("Sessions — multi-day") {
                PopoverContentView(state: .sessions(
                    MockScenario.multiDaySessions(now: Date()),
                    isRecording: true,
                    ringFilledBytes: MockScenario.heroRingFilledBytes,
                    ringCapacityBytes: MockScenario.heroRingCapacityBytes
                ))
            }
            labeled("Empty — at rest") {
                PopoverContentView(state: .empty(
                    ringFilledBytes: 0,
                    ringCapacityBytes: MockScenario.heroRingCapacityBytes
                ))
            }
            labeled("No mic access") {
                PopoverContentView(state: .noAccess)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Theme.bgRoom
                RadialGradient(colors: [Theme.amber.opacity(0.05), .clear], center: UnitPoint(x: 0.25, y: 0.2), startRadius: 0, endRadius: 500)
                RadialGradient(colors: [Theme.tapeGreen.opacity(0.03), .clear], center: UnitPoint(x: 0.8, y: 0.8), startRadius: 0, endRadius: 400)
            }
        )
        .onAppear {
            // Spike-only: force this unbundled executable to the front so it's visible
            // without relying on osascript/System Events (needs Accessibility permission
            // we may not have here).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            PanelContainer { content() }
            Text(title.uppercased())
                .font(.system(size: 12))
                .tracking(1.2)
                .foregroundStyle(Theme.creamFaint)
        }
    }
}
