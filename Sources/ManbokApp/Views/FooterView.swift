import SwiftUI
import AppKit
import ManbokPlatform

struct FooterView: View {
    private let log = AppLog(category: .app)
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Button(action: {
                log.notice("about: button tapped")
                NSApplication.shared.activate()
                openWindow(id: "about")
            }) {
                FooterHoverLabel(title: "About")
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {
                log.notice("settings: button tapped")
                NSApplication.shared.activate()
                openWindow(id: "settings")
            }) {
                FooterHoverLabel(title: "Settings…")
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {
                log.notice("quit: user requested termination")
                AppDelegate.shared?.allowTermination = true
                NSApplication.shared.terminate(nil)
            }) {
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
    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(isHovered ? tint.opacity(0.6) : tint)
            .onHover { isHovered = $0 }
    }
}
