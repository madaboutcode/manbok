import SwiftUI

struct AppIconView: View {
    let bundleID: String
    let displayName: String
    var size: CGFloat = 24

    private var cornerRadius: CGFloat { size * 0.22 }

    var body: some View {
        if let nsImage = AppIconProvider.shared.icon(for: bundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        let letter = String(displayName.prefix(1)).uppercased()
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colorForBundleID(bundleID))
            .frame(width: size, height: size)
            .overlay(
                Text(letter)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private func colorForBundleID(_ id: String) -> Color {
        let palette: [Color] = [
            .red, .orange, .purple, .blue,
            .teal, .indigo, .pink, .green,
        ]
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
