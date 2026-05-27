import SwiftUI

/// Selects a tasteful accent color from a home's extracted palette so
/// the UI can echo "this is YOUR home" without risking ugliness.
///
/// Why this exists: the raw palette can contain colors that look bad
/// when used as UI accents — pure white from sky pixels, near-black
/// from window mullions, desaturated grays from siding shadows. Picking
/// arbitrarily (e.g. `palette[1]`) regularly produces unusable results.
///
/// Strategy:
///   1. Walk the palette in order. The vision prompt that builds the
///      palette is explicitly told to surface distinctive accents like
///      a colored front door, so the LLM's ordering is meaningful.
///   2. Filter each color in HSL space — keep only ones with usable
///      lightness (not too dark, not too light) AND non-trivial
///      saturation (not a gray).
///   3. Return the first survivor. If nothing qualifies, return nil
///      and let the caller fall back to brass — the app's default
///      warm accent. The point is graceful degradation; the worst case
///      is the UI looks the same as it does before any palette is
///      extracted.
enum HomeAccent {

    /// Bounds tuned empirically: avoid near-black (l<0.25 blends into
    /// walnut), near-white (l>0.80 disappears on cream), and grays
    /// (s<0.22 reads as no-color-at-all). Mid-range, mid-saturated
    /// colors land as actual accents.
    private static let minLightness: Double = 0.25
    private static let maxLightness: Double = 0.80
    private static let minSaturation: Double = 0.22

    /// Pick the one usable accent color for this home. Returns nil if
    /// nothing in the palette is suitable; caller should fall back to
    /// `CaptainTheme.brass`.
    static func pick(from palette: [String]) -> Color? {
        for hex in palette {
            guard let hsl = hsl(hex: hex) else { continue }
            if hsl.l < minLightness || hsl.l > maxLightness { continue }
            if hsl.s < minSaturation { continue }
            return Color(hex: hex)
        }
        return nil
    }

    /// Convert "#rrggbb" / "rrggbb" to HSL components. Returns nil for
    /// malformed input. Lightness and saturation are 0…1; hue is 0…360.
    private static func hsl(hex: String) -> (h: Double, s: Double, l: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let int = UInt32(s, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xff) / 255.0
        let g = Double((int >> 8) & 0xff) / 255.0
        let b = Double(int & 0xff) / 255.0
        let maxc = max(r, g, b)
        let minc = min(r, g, b)
        let lightness = (maxc + minc) / 2.0
        let delta = maxc - minc
        let saturation: Double
        if delta < 1e-6 {
            saturation = 0
        } else if lightness > 0.5 {
            saturation = delta / (2.0 - maxc - minc)
        } else {
            saturation = delta / (maxc + minc)
        }
        var hue: Double
        if delta < 1e-6 {
            hue = 0
        } else if maxc == r {
            hue = (g - b) / delta
            if hue < 0 { hue += 6 }
        } else if maxc == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }
}
