import SwiftUI

/// Compact card on the home screen showing a *summary* of what's on the
/// owner's radar — a tone-calibrated lead line, a breakdown of streams
/// (calendar vs. AI suggestions), and a row of category icons hinting
/// at what's inside. Tap to open the full RadarView.
///
/// Quiet by default per PRD §7.5 — "things on the radar" without being
/// loud. Brass accents, cream-deep surface; same visual register as
/// WeatherWidget right above it.
struct RadarStrip: View {
    let radar: RadarResponse?
    var isLoading: Bool = false
    let onTap: () -> Void

    private var totalItems: Int {
        guard let radar else { return 0 }
        return radar.calendarItems.count + radar.suggestions.count
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if isLoading && radar == nil {
                    loadingRow
                } else if let radar, totalItems > 0 {
                    summaryRow(radar)
                    if let peek = peekItem(radar) {
                        Divider()
                            .background(CaptainTheme.brass.opacity(0.2))
                        peekRow(peek)
                    }
                } else {
                    Text("your radar is clear — nothing pressing")
                        .font(CaptainTheme.body(13))
                        .foregroundStyle(CaptainTheme.textMuted)
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
        .buttonStyle(.plain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("on your radar")
                .font(CaptainTheme.label(10))
                .foregroundStyle(CaptainTheme.textMuted)
                .tracking(1.0)
                .textCase(.uppercase)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CaptainTheme.brass)
        }
    }

    // MARK: - Summary row

    /// The radar's at-a-glance: lead line + breakdown + category icons.
    /// All three are derived from the response — no item is "featured."
    private func summaryRow(_ r: RadarResponse) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Allow up to 2 lines + downscale rather than truncating
                // mid-word on smaller phones — the lead can be longer
                // than the category-dots cluster leaves room for.
                Text(leadLine(r))
                    .font(CaptainTheme.body(14, weight: .medium))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = detailLine(r) {
                    Text(detail)
                        .font(CaptainTheme.body(11))
                        .foregroundStyle(CaptainTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
            }
            Spacer(minLength: 8)
            categoryDots(for: r)
        }
    }

    /// Warm, volume + urgency-aware headline. We bucket "this week" using
    /// either a calendar item in the next 7 days or a suggestion whose
    /// freeform timeframe text reads as imminent ("this weekend", "this
    /// week", "today", "tomorrow", "now"). Falls back to a plain count
    /// phrasing when nothing's urgent.
    private func leadLine(_ r: RadarResponse) -> String {
        let n = totalItems
        let urgent = imminentCount(r)
        if urgent > 0 {
            return "\(volumePhrase(urgent)) to consider this week"
        }
        // Nothing imminent — keep it understated.
        if n == 1 { return "one thing on your radar" }
        return "\(n) things on your radar"
    }

    /// "2 coming up · 4 to consider" when both streams have items.
    /// Single-stream cases collapse to a quieter detail line so we don't
    /// repeat the headline's count.
    private func detailLine(_ r: RadarResponse) -> String? {
        let cal = r.calendarItems.count
        let sug = r.suggestions.count
        switch (cal, sug) {
        case (0, 0): return nil
        case let (c, 0): return c == 1 ? "1 coming up" : "\(c) coming up"
        case let (0, s): return s == 1 ? "1 idea from Captain" : "\(s) ideas from Captain"
        case let (c, s): return "\(c) coming up · \(s) to consider"
        }
    }

    // MARK: - Peek row

    /// One line teasing the most-relevant single item under the summary.
    /// Prefers the soonest-dated calendar entry within two weeks; falls
    /// back to the top AI suggestion. Returns nil when neither stream
    /// produces something tease-worthy.
    private func peekItem(_ r: RadarResponse) -> PeekItem? {
        let soonCutoff = Date().addingTimeInterval(14 * 24 * 60 * 60)
        let imminent = r.calendarItems
            .filter { $0.kind == "future" }
            .compactMap { entry -> (CalendarEntry, Date)? in
                guard let d = parsedDate(entry.occurredAt) else { return nil }
                return (entry, d)
            }
            .filter { $0.1 <= soonCutoff }
            .min(by: { $0.1 < $1.1 })
        if let (cal, _) = imminent {
            return PeekItem(
                title: cal.text,
                when: formattedDate(cal.occurredAt) ?? "",
                icon: "calendar.circle.fill"
            )
        }
        if let s = r.suggestions.first {
            return PeekItem(
                title: s.title,
                when: s.timeframe,
                icon: categoryIcon(s.category)
            )
        }
        return nil
    }

    private struct PeekItem {
        let title: String
        let when: String
        let icon: String
    }

    private func peekRow(_ p: PeekItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: p.icon)
                .font(.system(size: 14))
                .foregroundStyle(CaptainTheme.brass)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                // LLM suggestion titles can be long; wrap rather than
                // truncate mid-word on narrow phones.
                Text(p.title)
                    .font(CaptainTheme.body(13, weight: .medium))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !p.when.isEmpty {
                    Text(p.when.lowercased())
                        .font(CaptainTheme.body(11))
                        .foregroundStyle(CaptainTheme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func formattedDate(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: iso) {
            let out = DateFormatter()
            out.dateFormat = "EEE, MMM d"
            return out.string(from: d)
        }
        return iso
    }

    /// Up to four distinct category icons in tiny brass circles. Order
    /// preserves first appearance (which the backend already orders by
    /// urgency/relevance). Calendar items contribute a calendar dot.
    private func categoryDots(for r: RadarResponse) -> some View {
        var seen: [String] = []
        if !r.calendarItems.isEmpty { seen.append("calendar.circle.fill") }
        for s in r.suggestions {
            let icon = categoryIcon(s.category)
            if !seen.contains(icon) { seen.append(icon) }
            if seen.count >= 4 { break }
        }
        return HStack(spacing: -6) {
            ForEach(seen.prefix(4), id: \.self) { icon in
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CaptainTheme.brass)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(CaptainTheme.cream)
                            .overlay(
                                Circle().strokeBorder(
                                    CaptainTheme.brass.opacity(0.45),
                                    lineWidth: 1
                                )
                            )
                    )
            }
        }
    }

    // MARK: - Loading

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(CaptainTheme.brass)
                .frame(width: 22)
            Text("captain is checking the radar…")
                .font(CaptainTheme.body(13))
                .foregroundStyle(CaptainTheme.textMuted)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    /// Count of items that feel like "this week" — calendar dates in the
    /// next 7 days OR suggestions whose timeframe text reads as imminent.
    private func imminentCount(_ r: RadarResponse) -> Int {
        let weekCutoff = Date().addingTimeInterval(7 * 24 * 60 * 60)
        let calSoon = r.calendarItems.filter { entry in
            guard entry.kind == "future",
                  let d = parsedDate(entry.occurredAt) else { return false }
            return d <= weekCutoff
        }.count

        let urgentWords = ["today", "tomorrow", "this week",
                           "this weekend", "now", "asap"]
        let sugSoon = r.suggestions.filter { s in
            let tf = s.timeframe.lowercased()
            return urgentWords.contains { tf.contains($0) }
        }.count

        return calSoon + sugSoon
    }

    /// Friendly volume word; falls back to the bare number for 5+.
    private func volumePhrase(_ n: Int) -> String {
        switch n {
        case 1:    return "one thing"
        case 2:    return "a couple things"
        case 3, 4: return "a handful of things"
        default:   return "\(n) things"
        }
    }

    private func parsedDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)
    }
}

/// Map category → SF Symbol. Shared with RadarView.
func categoryIcon(_ category: String) -> String {
    switch category.lowercased() {
    case "exterior":     return "house.fill"
    case "interior":     return "lamp.table.fill"
    case "landscaping":  return "leaf.fill"
    case "systems":      return "bolt.fill"
    case "seasonal":     return "sun.and.horizon.fill"
    case "followup":     return "arrow.triangle.turn.up.right.circle.fill"
    default:             return "sparkles"
    }
}

#Preview {
    VStack(spacing: 12) {
        RadarStrip(
            radar: RadarResponse(
                calendarItems: [
                    CalendarEntry(
                        id: 1, text: "Planning to repaint the back deck",
                        occurredAt: "2026-06-15", kind: "future",
                        source: "chat", createdAt: 0
                    ),
                    CalendarEntry(
                        id: 2, text: "Mow the lawn",
                        occurredAt: nil, kind: "recurring",
                        source: "chat", createdAt: 0
                    ),
                ],
                suggestions: [
                    RadarSuggestion(
                        title: "Prune the panicle hydrangeas",
                        reason: "Spring window closing.",
                        timeframe: "this weekend",
                        category: "landscaping"
                    ),
                    RadarSuggestion(
                        title: "HVAC condenser check-up",
                        reason: "Summer ramps fast.",
                        timeframe: "next 2 weeks",
                        category: "systems"
                    ),
                ],
                generatedAt: 0
            ),
            isLoading: false,
            onTap: {}
        )
        RadarStrip(radar: nil, isLoading: true, onTap: {})
        RadarStrip(
            radar: RadarResponse(
                calendarItems: [],
                suggestions: [],
                generatedAt: 0
            ),
            isLoading: false,
            onTap: {}
        )
    }
    .padding()
    .background(CaptainTheme.cream)
}
