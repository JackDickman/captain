import SwiftUI

/// Mid-century-modern design tokens.
///
/// The intent (per Jack's references): warm wood tones, brass accents, deep
/// forest-tile green, amber/honey stained glass. These are the *frame*; the
/// rendered home remains the main character.
enum CaptainTheme {

    // MARK: - Surface

    /// Primary page background — warm linen / cream.
    static let cream = Color(hex: "#f3ebdb")
    /// Slightly deeper cream for nested cards and input fields.
    static let creamDeep = Color(hex: "#e8dec8")

    // MARK: - Wood tones (walnut → honey → pine)

    static let walnut = Color(hex: "#5e3a23")
    static let wood = Color(hex: "#a16a3d")
    static let woodLight = Color(hex: "#c8956a")
    static let pine = Color(hex: "#d8b486")

    // MARK: - Metal

    static let brass = Color(hex: "#b8884a")
    static let brassBright = Color(hex: "#d4a560")

    // MARK: - Forest tile (the deep green kit-kat tile)

    static let tile = Color(hex: "#2d3f33")
    static let tileMid = Color(hex: "#4a5b46")

    // MARK: - Stained glass

    static let amber = Color(hex: "#c9742a")
    static let honey = Color(hex: "#e0a23c")
    static let rust = Color(hex: "#8b3a16")
    static let pale = Color(hex: "#f2dab0")
    static let ochre = Color(hex: "#b9802a")

    /// Mosaic palette used by StainedGlassPanel.
    static let stainedGlassColors: [Color] = [
        amber, honey, rust, pale, ochre, brassBright,
    ]

    // MARK: - Text

    /// Almost-black warm brown for primary text.
    static let textPrimary = Color(hex: "#2b1e15")
    /// Muted warm brown for secondary text.
    static let textMuted = Color(hex: "#7a6750")

    // MARK: - Fonts

    /// Display / brand serif (system serif at large sizes reads MCM enough).
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .serif)
    }

    /// Body / UI text.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Small uppercase label.
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }
}

// MARK: - Modifiers

extension View {
    /// Soft warm shadow — softer + warmer than the default digital drop shadow.
    func mcmShadow(intensity: Double = 1.0) -> some View {
        self
            .shadow(
                color: CaptainTheme.walnut.opacity(0.10 * intensity),
                radius: 12 * intensity, x: 0, y: 6 * intensity
            )
            .shadow(
                color: CaptainTheme.walnut.opacity(0.06 * intensity),
                radius: 3 * intensity, x: 0, y: 1
            )
    }
}
