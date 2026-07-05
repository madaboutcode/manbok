import SwiftUI
import AppKit

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
            Button("Open System Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.amber)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
