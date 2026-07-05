import SwiftUI

/// Scene 1: the vibe-check window. Plain dark room background with both popover
/// variants side by side, MOCK data, mirroring the mockup's "desk" layout.
struct VibeCheckView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            VStack(spacing: 14) {
                PanelContainer(width: 320) {
                    MainPopoverView()
                }
                Text("Option E \u{2014} Listening Post")
                    .font(.system(size: 12))
                    .tracking(1.2)
                    .foregroundStyle(Theme.creamFaint)
            }
            VStack(spacing: 14) {
                PanelContainer(width: 280) {
                    EmptyStateView()
                }
                Text("Empty state \u{2014} at rest")
                    .font(.system(size: 12))
                    .tracking(1.2)
                    .foregroundStyle(Theme.creamFaint)
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
            // Spike-only: force this unbundled executable to the front so a
            // screenshot captures it without relying on osascript/System Events
            // (which needs Accessibility permission we may not have here).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
