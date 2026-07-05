import SwiftUI
import AppKit

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Mic access needed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityAddTraits(.isHeader)
            Text("manbok needs microphone access to keep audio.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open System Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
