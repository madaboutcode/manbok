import SwiftUI
import AppKit

/// Ported from Sources/ManbokApp/Views/AppIconView.swift + Utilities/AppIconProvider.swift,
/// collapsed into one file and simplified: production's AppIconProvider tries several
/// bundle-ID candidates (AppIdentityCatalog, for helper processes reporting their parent's
/// bundle ID) before falling back. The spike only ever passes real, direct bundle IDs for
/// installed apps, so a single NSWorkspace lookup is enough — same visual result for the
/// cases that matter here (a resolved real icon or the lettered fallback tile).
struct AppIconView: View {
    let bundleID: String
    let displayName: String
    var size: CGFloat = 24

    private var cornerRadius: CGFloat { size * 0.22 }

    var body: some View {
        if let nsImage = MockAppIconProvider.icon(for: bundleID) {
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

    /// Identical hash-to-palette algorithm as production, so a given bundle ID gets
    /// the same fallback color here as it would in the real app.
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

enum MockAppIconProvider {
    static func icon(for bundleID: String) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}
