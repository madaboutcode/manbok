import SwiftUI

/// Spike-only chrome for the interactive "vibe check" window: since the real popover
/// gets its rounded corners from the hosting MenuBarExtra window (production draws no
/// border/shadow itself — see Theme.swift's PanelBackgroundView doc comment), a plain
/// PopoverContentView on a flat desk background would look like a raw rectangle. This
/// wrapper fakes the OS-drawn popover chrome so the interactive window looks right; the
/// offscreen PNG renderer (ScreenshotRenderer.swift) does the same for the same reason.
struct PanelContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.lineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 12)
    }
}
