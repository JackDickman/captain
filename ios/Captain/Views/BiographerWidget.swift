import SwiftUI

/// Home-screen widget for Captain's "on this day" recall (PRD §6.7
/// biographer surfaces). Same visual chrome as WeatherWidget and
/// RadarStrip — cream-deep card, brass-tinted border, small uppercase
/// label — so it reads as a peer in the home-screen stack rather than
/// a footnote crammed above the chat capsule.
///
/// Quiet by default: an open book glyph, a single line of italic prose,
/// nothing else. No tap target — this is decorative presence, not a
/// destination. The parent only mounts the widget when the backend has
/// something to say; on most days the home screen renders without it.
struct BiographerWidget: View {
    let recall: BiographerRecall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(CaptainTheme.brass)
                    // Pin the glyph to the first text line so longer
                    // recall lines don't lift it up the column.
                    .padding(.top, 1)
                Text(recall.text)
                    .font(CaptainTheme.body(14))
                    .italic()
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(CaptainTheme.creamDeep.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.35),
                            lineWidth: 1
                        )
                )
        )
    }

    /// Matches the "ON YOUR RADAR" label on RadarStrip — small caps,
    /// brass-tinted muted text, same tracking and case so the two
    /// widgets stack as visual peers.
    private var header: some View {
        Text("on this day")
            .font(CaptainTheme.label(10))
            .foregroundStyle(CaptainTheme.textMuted)
            .tracking(1.0)
            .textCase(.uppercase)
    }
}

#Preview {
    VStack(spacing: 14) {
        BiographerWidget(recall: BiographerRecall(
            text: "A year ago today, lilacs along the back fence were almost ready to bloom.",
            occurredAt: "2025-05-29",
            entryText: "Noticed the lilacs were about to bloom along the back fence"
        ))
        BiographerWidget(recall: BiographerRecall(
            text: "Last spring around now, the front-bed mulching went down.",
            occurredAt: "2025-05-25",
            entryText: "Mulched the front beds"
        ))
    }
    .padding()
    .background(CaptainTheme.cream)
}
