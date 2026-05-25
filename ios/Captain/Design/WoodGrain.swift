import SwiftUI

/// Procedural wood-grain background. A warm honey base with subtle horizontal
/// grain lines and slight variation. Used as the surface texture for
/// "cabinetry" elements like the chat bar.
///
/// Cheap to render: just a gradient plus a small Canvas of low-opacity
/// strokes. No image assets required.
struct WoodGrain: View {
    /// Direction of the grain. Most cabinetry runs horizontally.
    var orientation: Orientation = .horizontal

    enum Orientation {
        case horizontal
        case vertical
    }

    var body: some View {
        ZStack {
            // Warm base — honey to walnut, slight diagonal so it doesn't feel flat
            LinearGradient(
                colors: [
                    CaptainTheme.pine,
                    CaptainTheme.woodLight,
                    CaptainTheme.wood,
                    CaptainTheme.walnut.opacity(0.85),
                ],
                startPoint: orientation == .horizontal ? .topLeading : .leading,
                endPoint: orientation == .horizontal ? .bottomTrailing : .trailing
            )

            // Subtle grain lines
            Canvas { ctx, size in
                let length = orientation == .horizontal ? size.height : size.width
                let span = orientation == .horizontal ? size.width : size.height
                let step: CGFloat = 2.4
                var i: CGFloat = 0
                while i < length {
                    // Pseudo-noise: layered sines for organic line wander
                    let wobble = sin(i * 0.18) * 4 + cos(i * 0.31 + 1.2) * 2
                    let opacity = 0.05 + 0.06 * abs(sin(i * 0.09))
                    var line = Path()
                    if orientation == .horizontal {
                        line.move(to: CGPoint(x: 0, y: i + wobble))
                        line.addLine(to: CGPoint(x: span, y: i + wobble + sin(i * 0.05) * 2))
                    } else {
                        line.move(to: CGPoint(x: i + wobble, y: 0))
                        line.addLine(to: CGPoint(x: i + wobble + sin(i * 0.05) * 2, y: span))
                    }
                    ctx.stroke(
                        line,
                        with: .color(CaptainTheme.walnut.opacity(opacity)),
                        lineWidth: 0.5
                    )
                    i += step
                }
            }
            .blendMode(.multiply)
            .allowsHitTesting(false)
        }
    }
}

#Preview {
    WoodGrain()
        .frame(width: 300, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding()
}
