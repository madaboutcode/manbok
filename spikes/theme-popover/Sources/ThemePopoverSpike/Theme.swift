import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Color tokens ported 1:1 from tasks/mockups/option-e-listening-post.html :root.
enum Theme {
    static let bgRoom = Color(hex: 0x0C0A08)
    static let bgPanel = Color(hex: 0x1B1611)
    static let bgPanelTop = Color(hex: 0x1F1A14)
    static let bgWell = Color(hex: 0x14100C)

    private static let lineBase = Color(hex: 0xD6B684)
    static let line = lineBase.opacity(0.10)
    static let lineStrong = lineBase.opacity(0.16)

    static let cream = Color(hex: 0xF1E6D3)
    static let creamDim = Color(hex: 0xCBB99E)
    static let creamFaint = Color(hex: 0x8D7D68)

    static let amber = Color(hex: 0xE0A951)
    static let amberHot = Color(hex: 0xFFB84D)
    static let amberGlow = Color(hex: 0xE0A951, opacity: 0.35)

    static let tapeGreen = Color(hex: 0x8FBF7A)
    static let tapeGreenDim = Color(hex: 0x5D7A53)

    static let danger = Color(hex: 0xC96A4F)
}

extension Font {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
