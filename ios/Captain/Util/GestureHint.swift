import SwiftUI

/// Subtle, decaying "this is tappable" affordance for gesture-driven UI
/// (PRD §7.9: gesture discoverability). The first time the user sees a
/// hinted view, a soft brass ring breathes around it on a slow loop.
/// On first tap, `GestureHint.markDiscovered(_:)` is called and the ring
/// disappears forever (persisted in `UserDefaults` so reinstalling resets).
///
/// Goals:
///   - Affordance, not chrome — no captions, no arrows, no overlays the
///     designer didn't already approve.
///   - One-time — once the user has tapped, the ring is gone for good.
///   - Cheap — pure SwiftUI; no animation framework, no haptics, no images.
///
/// Usage:
///     RadarStrip(radar: radar) { … }
///         .gestureHint(.radarCard)
///
///     // In the tap handler:
///     GestureHint.markDiscovered(.radarCard)
///
/// Add a new hint by appending a case to `GestureHint.Key`.

enum GestureHint {
    /// Stable identifiers for each hinted surface. Adding a new key is
    /// free; removing one cleans up `UserDefaults` on next launch via
    /// the modifier's @AppStorage binding still defaulting to false.
    enum Key: String {
        case radarCard       = "radarCard"
        case cornerAvatar    = "cornerAvatar"
    }

    private static let prefix = "captain.hint."

    /// Has the user already discovered this surface? Synchronous read
    /// for use outside SwiftUI (e.g. event logging).
    static func isDiscovered(_ key: Key) -> Bool {
        UserDefaults.standard.bool(forKey: prefix + key.rawValue)
    }

    /// Mark the surface as discovered. Idempotent. Triggers a re-render
    /// of any view bound to the matching @AppStorage key.
    static func markDiscovered(_ key: Key) {
        UserDefaults.standard.set(true, forKey: prefix + key.rawValue)
    }

    /// Dev-only: clear all hints so they reappear on next launch.
    /// Wired to AppState.reset() so a fresh first-session also re-arms
    /// the gesture hints.
    static func resetAll() {
        for k in [Key.radarCard, .cornerAvatar] {
            UserDefaults.standard.removeObject(forKey: prefix + k.rawValue)
        }
    }
}

private struct GestureHintModifier: ViewModifier {
    let key: GestureHint.Key
    /// AppStorage binding so the ring disappears the instant the user
    /// taps (the tap handler calls markDiscovered → UserDefaults
    /// updates → SwiftUI re-renders this modifier).
    @AppStorage private var discovered: Bool
    /// Drives the ring's slow breathing animation.
    @State private var phase: CGFloat = 0

    init(key: GestureHint.Key) {
        self.key = key
        _discovered = AppStorage(
            wrappedValue: false, "captain.hint." + key.rawValue
        )
    }

    func body(content: Content) -> some View {
        content.overlay(
            Group {
                if !discovered {
                    GeometryReader { proxy in
                        // Match the hinted view's outer bounds with a
                        // rounded brass ring; the corner radius is
                        // approximate (we don't know the host's exact
                        // radius). For the two current callsites
                        // (radar card = 14, avatar = a Circle) a
                        // 14pt rounded rect is close enough on the
                        // card and the Circle host clips on its own.
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                CaptainTheme.brassBright,
                                lineWidth: 1.2
                            )
                            .opacity(0.20 + 0.35 * phase)
                            .scaleEffect(1.0 + 0.012 * phase)
                            .frame(
                                width: proxy.size.width,
                                height: proxy.size.height
                            )
                            .allowsHitTesting(false)
                    }
                }
            }
        )
        .onAppear {
            guard !discovered else { return }
            withAnimation(
                .easeInOut(duration: 1.8)
                .repeatForever(autoreverses: true)
            ) {
                phase = 1
            }
        }
    }
}

extension View {
    /// Apply a one-time gesture hint to this view. The hint shows a
    /// breathing brass ring until the user taps the underlying view
    /// (which is expected to call `GestureHint.markDiscovered(key)`).
    func gestureHint(_ key: GestureHint.Key) -> some View {
        modifier(GestureHintModifier(key: key))
    }
}
