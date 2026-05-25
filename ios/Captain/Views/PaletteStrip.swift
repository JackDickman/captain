import SwiftUI

/// Thin capsule-clipped strip of palette swatches, used as a quiet accent
/// throughout the app to signal "this home's colors."
struct PaletteStrip: View {
    let colors: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(colors, id: \.self) { hex in
                Rectangle()
                    .fill(Color(hex: hex))
            }
        }
        .clipShape(Capsule())
    }
}
