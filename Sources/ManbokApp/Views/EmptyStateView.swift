import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "ear")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Listening...")
                .font(.system(size: 12, weight: .medium))
            Text("When an app uses your mic, manbok will keep the audio here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
