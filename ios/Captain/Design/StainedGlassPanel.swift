import SwiftUI

/// A stained-glass mosaic built from the reference image's construction
/// language: each cell is a rectangle in which one (or two opposite) corner(s)
/// has been replaced by a large quarter-circle arc. The radius is a high
/// fraction of the cell's smaller dimension, so the curve dominates the cell
/// rather than being a subtle rounded corner. Dark walnut "leading" between
/// cells, glass-highlight gradient overlay, and a slight noise overlay
/// hint at the hand-blown glass texture.
///
/// Colors cycle slowly when `animated`; geometry is fully deterministic and
/// stable across frames (cells don't shift, only fills update).
///
/// Designed full-bleed for the loading screen; the row/col defaults are
/// portrait-appropriate.
struct StainedGlassPanel: View {
    var palette: [String] = []
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

    // MARK: - Geometry

    /// The seven cell shapes — plain rectangle, four single-corner arcs, and
    /// two "leaf" variants where two opposite corners are arced (forming a
    /// dramatic diagonal sweep). All quarter-circles use the same radius
    /// (a fraction of the cell's smaller dimension) so adjacent cells'
    /// curves read as the same hand-leaded language.
    private enum CellShape {
        case plain
        case arcTL
        case arcTR
        case arcBR
        case arcBL
        case leafTLBR  // TL and BR both arced → leaf from BL to TR
        case leafTRBL  // TR and BL both arced → leaf from TL to BR
    }

    /// Deterministic shape per (r, c). Weighted strongly toward curved
    /// shapes — plain rectangles are a minority so the mosaic reads as
    /// flowing rather than gridded.
    private func shape(at r: Int, _ c: Int) -> CellShape {
        let h = (r * 47 &+ c * 31 &+ 11) & 0x7fff
        switch h % 12 {
        case 0, 1:        return .arcTL
        case 2, 3:        return .arcTR
        case 4, 5:        return .arcBR
        case 6, 7:        return .arcBL
        case 8:           return .leafTLBR
        case 9:           return .leafTRBL
        default:          return .plain
        }
    }

    private func cellPath(
        x0: CGFloat, y0: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat,
        shape: CellShape
    ) -> Path {
        let x1 = x0 + w
        let y1 = y0 + h
        var p = Path()

        switch shape {
        case .plain:
            p.addRect(CGRect(x: x0, y: y0, width: w, height: h))

        case .arcTL:
            // TL corner replaced by a quarter-circle whose two endpoints lie
            // on the top and left edges at distance r from the original TL.
            p.move(to: CGPoint(x: x0, y: y1))
            p.addLine(to: CGPoint(x: x0, y: y0 + r))
            p.addArc(
                center: CGPoint(x: x0 + r, y: y0 + r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: x1, y: y0))
            p.addLine(to: CGPoint(x: x1, y: y1))
            p.closeSubpath()

        case .arcTR:
            p.move(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x1 - r, y: y0))
            p.addArc(
                center: CGPoint(x: x1 - r, y: y0 + r),
                radius: r,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x0, y: y1))
            p.closeSubpath()

        case .arcBR:
            p.move(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x1, y: y0))
            p.addLine(to: CGPoint(x: x1, y: y1 - r))
            p.addArc(
                center: CGPoint(x: x1 - r, y: y1 - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: x0, y: y1))
            p.closeSubpath()

        case .arcBL:
            p.move(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x1, y: y0))
            p.addLine(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x0 + r, y: y1))
            p.addArc(
                center: CGPoint(x: x0 + r, y: y1 - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            p.closeSubpath()

        case .leafTLBR:
            // Both TL and BR arced — leaf-shape from BL through to TR.
            p.move(to: CGPoint(x: x0, y: y1))
            p.addLine(to: CGPoint(x: x0, y: y0 + r))
            p.addArc(
                center: CGPoint(x: x0 + r, y: y0 + r),
                radius: r,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: x1, y: y0))
            p.addLine(to: CGPoint(x: x1, y: y1 - r))
            p.addArc(
                center: CGPoint(x: x1 - r, y: y1 - r),
                radius: r,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
            p.closeSubpath()

        case .leafTRBL:
            p.move(to: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x1 - r, y: y0))
            p.addArc(
                center: CGPoint(x: x1 - r, y: y0 + r),
                radius: r,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )
            p.addLine(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x0 + r, y: y1))
            p.addArc(
                center: CGPoint(x: x0 + r, y: y1 - r),
                radius: r,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
            p.closeSubpath()
        }
        return p
    }

    // MARK: - Render

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)
        // Quarter-circle radius — large fraction of the cell dimension so
        // curves dominate (matches the reference, where arcs almost reach
        // the opposite corner of their cell).
        let radius = min(cellW, cellH) * 0.78
        let pal = effectivePalette

        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = CGFloat(c) * cellW
                let y0 = CGFloat(r) * cellH
                let kind = shape(at: r, c)
                let path = cellPath(
                    x0: x0, y0: y0,
                    w: cellW, h: cellH,
                    r: radius,
                    shape: kind
                )

                // Color: stable seed per cell, offset by global phase so
                // tiles slowly cycle through the palette together.
                let seed = (r * 7 + c * 11 + 3) % pal.count
                let idx = (seed + phase * (1 + (r + c) % 3)) % pal.count
                ctx.fill(path, with: .color(pal[idx]))

                // Glass highlight — diagonal sheen across the cell.
                ctx.fill(path, with: .linearGradient(
                    Gradient(colors: [
                        .white.opacity(0.22),
                        .clear,
                        .black.opacity(0.10),
                    ]),
                    startPoint: CGPoint(x: x0, y: y0),
                    endPoint: CGPoint(x: x0 + cellW, y: y0 + cellH)
                ))

                // Dark walnut "leading" — runs along every cell boundary
                // (straight or arced). Drawn slightly thick so adjacent
                // cells' edges overlap and the seam reads as continuous.
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
    StainedGlassPanel(rows: 10, cols: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
}
