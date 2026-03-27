import SwiftUI

/// Design tokens adapted from devbar's Sacred Computer terminal aesthetic.
/// Dark background, emerald accent, monospaced typography.
enum Theme {
    // Primary
    static let emerald = Color(hex: 0x10B981)
    static let emeraldHover = Color(hex: 0x059669)
    static let emeraldGlow = Color(hex: 0x10B981).opacity(0.4)

    // Semantic
    static let error = Color(hex: 0xEF4444)
    static let warning = Color(hex: 0xF59E0B)
    static let info = Color(hex: 0x3B82F6)

    // Extended
    static let purple = Color(hex: 0xA855F7)
    static let cyan = Color(hex: 0x06B6D4)
    static let pink = Color(hex: 0xEC4899)

    // Backgrounds
    static let bg = Color(hex: 0x0A0F1A)
    static let bgCard = Color(hex: 0x111827).opacity(0.95)
    static let bgElevated = Color(hex: 0x111827).opacity(0.98)

    // Text
    static let text = Color(hex: 0xF1F5F9)
    static let textSecondary = Color(hex: 0x94A3B8)
    static let textMuted = Color(hex: 0x6B7280)

    // Borders
    static let border = Color(hex: 0x10B981).opacity(0.2)
    static let borderSubtle = Color(hex: 0x10B981).opacity(0.1)

    // Fonts — Departure Mono for headers/UI, system mono fallback
    static let fontName = "Departure Mono"

    static let mono = Font.custom(fontName, size: 14)
    static let monoSmall = Font.custom(fontName, size: 12)
    static let monoTiny = Font.custom(fontName, size: 11)
    static let monoTitle = Font.custom(fontName, size: 16)
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
