import SwiftUI

/// A stained-glass mosaic — a simple grid of square panes in the home's
/// (or the default app) palette. Each pane has a diagonal glass-highlight
/// sheen and dark walnut "leading" along its edges, so the seams read
/// like hand-leaded lead came.
///
/// Colors cycle slowly when `animated`; geometry is fully deterministic
/// and stable across frames (panes don't shift, only fills update).
///
/// Designed full-bleed for the loading screen. Cells are sized as
/// perfect squares derived from `cols` + the available width; row count
/// fills to the bottom of the canvas regardless of how tall it is.
struct StainedGlassPanel: View {
    var palette: [String] = []
    /// Kept for call-site compatibility; the actual row count is derived
    /// from the canvas height so cells stay square.
    var rows: Int = 8
    var cols: Int = 5
    var animated: Bool = true

    @State private var phase: Int = 0
    private let timer = Timer.publish(
        every: 1.8, on: .main, in: .common
    ).autoconnect()

    private var effectivePalette: [Color] {
        let mapped = palette.map { Color(hex: $0) }
        return mapped.count >= 3 ? mapped : CaptainTheme.stainedGlassColors
    }

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
        .background(CaptainTheme.walnut)
        .onReceive(timer) { _ in
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.1)) {
                phase += 1
            }
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let cellSize = size.width / CGFloat(cols)
        let derivedRows = max(1, Int(ceil(size.height / cellSize)))
        let pal = effectivePalette

        for r in 0..<derivedRows {
            for c in 0..<cols {
                let x0 = CGFloat(c) * cellSize
                let y0 = CGFloat(r) * cellSize
                let rect = CGRect(x: x0, y: y0,
                                  width: cellSize, height: cellSize)
                let path = Path(rect)

                // Color: stable seed per cell, offset by global phase so
                // tiles slowly cycle through the palette together.
                let seed = (r * 7 + c * 11 + 3) % pal.count
                let idx = (seed + phase * (1 + (r + c) % 3)) % pal.count
                ctx.fill(path, with: .color(pal[idx]))

                // Glass highlight — diagonal sheen across the pane.
                ctx.fill(path, with: .linearGradient(
                    Gradient(colors: [
                        .white.opacity(0.22),
                        .clear,
                        .black.opacity(0.10),
                    ]),
                    startPoint: CGPoint(x: x0, y: y0),
                    endPoint: CGPoint(x: x0 + cellSize, y: y0 + cellSize)
                ))

                // Dark walnut "leading" along every edge. Drawn slightly
                // thick so adjacent panes' edges overlap and the seam
                // reads as a continuous lead came.
                ctx.stroke(
                    path,
                    with: .color(CaptainTheme.walnut),
                    lineWidth: 2.6
                )
            }
        }
    }
}

#Preview {
    StainedGlassPanel(cols: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
}
