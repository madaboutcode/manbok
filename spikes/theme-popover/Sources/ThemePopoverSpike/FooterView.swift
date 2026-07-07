import SwiftUI

/// Ported from Sources/ManbokApp/Views/FooterView.swift. Production buttons open the
/// About/Settings windows or quit the app via NSApplication/openWindow — none of that
/// applies to a static render, so the buttons here have no action, but the exact layout,
/// spacing, and hover-label styling (buttonStyle(.plain) means resting state already
/// looks identical to production) are kept.
struct FooterView: View {
    var body: some View {
        HStack {
            Button(action: {}) {
                FooterHoverLabel(title: "About")
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {}) {
                FooterHoverLabel(title: "Settings…")
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {}) {
                FooterHoverLabel(title: "Quit", tint: Theme.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct FooterHoverLabel: View {
    let title: String
    var tint: Color = Theme.creamDim

    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(tint)
    }
}
