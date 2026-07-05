import SwiftUI
import AppKit
import ManbokPlatform

struct FooterView: View {
    private let log = AppLog(category: .app)
    @Environment(\.openSettings) private var openSettings
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
                openSettings()
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
                FooterHoverLabel(title: "Quit", tint: .red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct FooterHoverLabel: View {
    let title: String
    var tint: Color = .primary
    @State private var isHovered = false

    var body: some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(isHovered ? tint.opacity(0.6) : tint)
            .onHover { isHovered = $0 }
    }
}
