import SwiftUI

/// Ported from Sources/ManbokApp/Views/PermissionDeniedView.swift, with one
/// ImageRenderer-driven substitution: production's `Button(...).buttonStyle(.borderedProminent)`
/// depends on AppKit's live control rendering to draw its chrome. Offscreen (no window
/// server backing this render), that button drew as a broken amber rectangle with a
/// "not allowed" glyph instead of its label — a real AppKit/ImageRenderer limitation,
/// not a bug in this view. Swapped for a hand-drawn pill that matches
/// `.borderedProminent` + `.tint(Theme.amber)`'s actual on-screen look (amber fill,
/// dark text) without going through NSButton.
struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Mic access needed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.amberHot)
                .accessibilityAddTraits(.isHeader)
            Text("manbok needs microphone access to keep audio.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.creamFaint)
                .multilineTextAlignment(.center)
            Text("Open System Settings…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.amber))
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
