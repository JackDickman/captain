import SwiftUI

extension Color {
    /// Lenient hex initializer. Accepts "#rrggbb" or "rrggbb"; falls back to
    /// gray on malformed input rather than crashing — the backend should send
    /// well-formed hexes, but we don't want a bad palette to nuke the UI.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let int = UInt64(s, radix: 16) else {
            self = .gray
            return
        }
        let r = Double((int >> 16) & 0xff) / 255.0
        let g = Double((int >> 8) & 0xff) / 255.0
        let b = Double(int & 0xff) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
