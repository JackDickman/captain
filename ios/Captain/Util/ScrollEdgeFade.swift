import SwiftUI

/// Soft alpha fade at the top and bottom edges of a scrolling view.
/// Used on every ScrollView in Captain so content slides under fixed
/// chrome (or runs into the safe-area edge) with the same cushion
/// everywhere — instead of clipping hard against the pinned header,
/// pinned input bar, or device bezel.
///
/// The fade is bound to the host view's own bounds via GeometryReader,
/// so the cushion distance stays constant whatever the content height,
/// and a zero-height pre-measure pass can't divide-by-zero.
///
/// Defaults: 22pt of fade at the top, 26pt at the bottom (slightly
/// heavier below to give floating elements like the chat input or
/// chat capsule more breathing room than a flat title bar above).
private struct ScrollEdgeFadeMask: View {
    let topPoints: CGFloat
    let bottomPoints: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let topFrac = h > 0 ? min(topPoints / h, 0.2) : 0.03
            let bottomFrac = h > 0 ? min(bottomPoints / h, 0.2) : 0.04
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: topFrac),
                    .init(color: .black, location: 1 - bottomFrac),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

extension View {
    /// Captain's standard scroll-edge fade. Apply to any vertically
    /// scrolling surface that sits beneath or above pinned chrome — or
    /// just to soften the device-bezel edge. Same defaults everywhere
    /// so the app feels consistent surface-to-surface.
    func captainScrollEdgeFade(
        topPoints: CGFloat = 22,
        bottomPoints: CGFloat = 26,
    ) -> some View {
        mask(
            ScrollEdgeFadeMask(
                topPoints: topPoints,
                bottomPoints: bottomPoints,
            )
        )
    }
}
