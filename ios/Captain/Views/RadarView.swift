import SwiftUI

/// The full radar surface — what's coming up + things to consider.
/// Presented as a sheet from the home-screen RadarStrip. Two sections:
/// "Coming up" (calendar items sorted by date) and "Things to consider"
/// (AI suggestions, each with title + reason + timeframe + category).
struct RadarView: View {
    let radar: RadarResponse
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CaptainTheme.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !radar.calendarItems.isEmpty {
                            sectionHeading("Coming up")
                            VStack(spacing: 10) {
                                ForEach(radar.calendarItems) { entry in
                                    calendarRow(entry)
                                }
                            }
                        }
                        if !radar.suggestions.isEmpty {
                            sectionHeading("Things to consider")
                            VStack(spacing: 10) {
                                ForEach(radar.suggestions) { s in
                                    suggestionCard(s)
                                }
                            }
                        }
                        if radar.calendarItems.isEmpty
                            && radar.suggestions.isEmpty {
                            emptyState
                        }
                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(CaptainTheme.creamDeep))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("on your radar")
                    .font(CaptainTheme.body(13))
                    .foregroundStyle(CaptainTheme.textMuted)
                Text(totalLabel)
                    .font(CaptainTheme.display(15))
                    .foregroundStyle(CaptainTheme.textPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CaptainTheme.cream)
    }

    private var totalLabel: String {
        let n = radar.calendarItems.count + radar.suggestions.count
        if n == 0 { return "all clear" }
        if n == 1 { return "1 thing" }
        return "\(n) things"
    }

    // MARK: - Section heading

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(CaptainTheme.label(11))
            .foregroundStyle(CaptainTheme.textMuted)
            .tracking(1.2)
            .textCase(.uppercase)
            .padding(.top, 4)
    }

    // MARK: - Calendar row

    private func calendarRow(_ entry: CalendarEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.kind == "recurring"
                  ? "arrow.triangle.2.circlepath"
                  : "calendar.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(CaptainTheme.brass)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(CaptainTheme.body(15, weight: .medium))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let when = formattedDate(entry.occurredAt) {
                    Text(when)
                        .font(CaptainTheme.body(12))
                        .foregroundStyle(CaptainTheme.textMuted)
                } else if entry.kind == "recurring" {
                    Text("ongoing")
                        .font(CaptainTheme.body(12))
                        .foregroundStyle(CaptainTheme.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CaptainTheme.creamDeep.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(CaptainTheme.brass.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Suggestion card

    private func suggestionCard(_ s: RadarSuggestion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: categoryIcon(s.category))
                .font(.system(size: 18))
                .foregroundStyle(CaptainTheme.brass)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(s.title)
                        .font(CaptainTheme.body(15, weight: .medium))
                        .foregroundStyle(CaptainTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Text(s.reason)
                    .font(CaptainTheme.body(13))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if !s.timeframe.isEmpty {
                    Text(s.timeframe.lowercased())
                        .font(CaptainTheme.label(10))
                        .foregroundStyle(CaptainTheme.brass)
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CaptainTheme.creamDeep.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(CaptainTheme.brass.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(CaptainTheme.brass.opacity(0.7))
            Text("nothing on your radar right now")
                .font(CaptainTheme.body(14))
                .foregroundStyle(CaptainTheme.textMuted)
            Text("As Captain learns more about your home, it'll suggest things here.")
                .font(CaptainTheme.body(12))
                .foregroundStyle(CaptainTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func formattedDate(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: iso) {
            let out = DateFormatter()
            out.dateFormat = "EEEE, MMMM d"
            return out.string(from: d)
        }
        return iso
    }
}

#Preview {
    RadarView(radar: RadarResponse(
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
                reason: "Panicle hydrangeas bloom on new wood — your zone 6a spring window is closing.",
                timeframe: "this weekend",
                category: "landscaping"
            ),
            RadarSuggestion(
                title: "Pet-safe lawn treatment plan",
                reason: "Since Jackie sniffs the grass constantly, switch to organic dandelion control.",
                timeframe: "next 2 weeks",
                category: "landscaping"
            ),
        ],
        generatedAt: 0
    ))
}
