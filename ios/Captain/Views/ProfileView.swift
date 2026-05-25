import SwiftUI

/// The corner-avatar drawer (PRD §7.7). Three quiet tabs: what Captain
/// knows about the home, what it knows about the owner, and the full
/// calendar / "biography" of past + upcoming items.
///
/// This surface is intentionally calm — the owner rarely visits, the
/// content is the point. No edit controls in v1; corrections happen via
/// chat and the magic-memory loop rewrites the profiles in place.
struct ProfileView: View {
    let session: FirstSessionResponse
    @Environment(\.dismiss) private var dismiss

    @State private var profile: ProfileResponse?
    @State private var tab: Tab = .home
    @State private var loadError: String?

    enum Tab: Hashable { case home, owner, calendar }

    var body: some View {
        ZStack {
            CaptainTheme.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabBar
                ScrollView { content.padding(.horizontal, 20).padding(.vertical, 18) }
            }
        }
        .task { await load() }
        .onAppear {
            // Debug: --profile-tab=owner|calendar to land on a specific tab.
            for arg in ProcessInfo.processInfo.arguments {
                if arg == "--profile-tab=owner" { tab = .owner }
                if arg == "--profile-tab=calendar" { tab = .calendar }
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
                Text("what Captain knows")
                    .font(CaptainTheme.body(13))
                    .foregroundStyle(CaptainTheme.textMuted)
                Text(profile?.address ?? session.address)
                    .font(CaptainTheme.display(15))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CaptainTheme.cream)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("home", tab: .home)
            tabButton("owner", tab: .owner)
            tabButton("calendar", tab: .calendar)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(CaptainTheme.cream)
    }

    private func tabButton(_ title: String, tab tabKind: Tab) -> some View {
        let selected = tab == tabKind
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { tab = tabKind }
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(CaptainTheme.label(12))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(
                        selected ? CaptainTheme.textPrimary
                                 : CaptainTheme.textMuted
                    )
                Rectangle()
                    .fill(selected
                          ? CaptainTheme.brass
                          : CaptainTheme.brass.opacity(0.0))
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var content: some View {
        if let error = loadError {
            Text(error)
                .font(CaptainTheme.body(13))
                .foregroundStyle(CaptainTheme.rust)
        } else if profile == nil {
            ProgressView()
                .tint(CaptainTheme.brass)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else {
            switch tab {
            case .home:
                MarkdownView(markdown: profile?.homeMd ?? "")
            case .owner:
                MarkdownView(markdown: profile?.userMd ?? "")
            case .calendar:
                CalendarList(entries: profile?.calendar ?? [])
            }
        }
    }

    // MARK: - Network

    private func load() async {
        do {
            profile = try await CaptainAPI.fetchProfile()
        } catch {
            loadError = "couldn't load profile: \(error.localizedDescription)"
        }
    }
}

// MARK: - CalendarList

/// Compact list of calendar entries with a small "kind" pill. Past items
/// sit chronologically; future items are highlighted in brass; recurring
/// items wear an arrow pair.
struct CalendarList: View {
    let entries: [CalendarEntry]

    var body: some View {
        if entries.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sorted) { entry in
                    row(entry)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 28))
                .foregroundStyle(CaptainTheme.brass.opacity(0.7))
            Text("nothing on the calendar yet")
                .font(CaptainTheme.body(14))
                .foregroundStyle(CaptainTheme.textMuted)
            Text("Captain will quietly add things as you mention them.")
                .font(CaptainTheme.body(12))
                .foregroundStyle(CaptainTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// Sort: future items first by ascending date (soonest at top), then
    /// past/observation items by descending date (most recent first), then
    /// undated recurring items at the bottom.
    private var sorted: [CalendarEntry] {
        let future = entries.filter { $0.kind == "future" }
            .sorted { ($0.occurredAt ?? "") < ($1.occurredAt ?? "") }
        let historical = entries.filter {
            $0.kind == "past" || $0.kind == "observation"
        }
        .sorted { ($0.occurredAt ?? "") > ($1.occurredAt ?? "") }
        let recurring = entries.filter { $0.kind == "recurring" }
        return future + historical + recurring
    }

    private func row(_ entry: CalendarEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                Image(systemName: kindIcon(entry.kind))
                    .font(.system(size: 14))
                    .foregroundStyle(kindColor(entry.kind))
                    .frame(width: 22, height: 22)
                Text(entry.kind)
                    .font(CaptainTheme.label(8))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }
            .frame(width: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(CaptainTheme.body(14))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let dateStr = entry.occurredAt, !dateStr.isEmpty {
                    Text(formatted(dateStr))
                        .font(CaptainTheme.body(11))
                        .foregroundStyle(CaptainTheme.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CaptainTheme.creamDeep.opacity(0.45))
        )
    }

    private func kindIcon(_ kind: String) -> String {
        switch kind {
        case "future":      return "arrow.forward.circle.fill"
        case "past":        return "checkmark.circle.fill"
        case "recurring":   return "arrow.triangle.2.circlepath"
        case "observation": return "eye.fill"
        default:            return "circle.fill"
        }
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "future":      return CaptainTheme.brass
        case "past":        return CaptainTheme.textMuted
        case "recurring":   return CaptainTheme.tileMid
        case "observation": return CaptainTheme.rust
        default:            return CaptainTheme.textMuted
        }
    }

    /// "2026-05-25" -> "May 25, 2026". Falls back to raw string for
    /// datetime-style values.
    private func formatted(_ iso: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: iso) {
            let out = DateFormatter()
            out.dateFormat = "MMMM d, yyyy"
            return out.string(from: d)
        }
        return iso
    }
}

#Preview {
    ProfileView(session: .previewForProfile)
}

private extension FirstSessionResponse {
    static let previewForProfile = FirstSessionResponse(
        jobId: "preview",
        address: "4221 Silsby Rd, University Heights, OH 44118",
        currentSeason: "spring",
        currentRenderingUrl: "/rendered/fixture-silsby/spring.png",
        renderings: [:],
        palette: ["#b22222", "#ffffff", "#a9a9a9",
                  "#d2b48c", "#000000", "#ffd700"],
        features: [],
        sourceUrls: [],
        fixture: true
    )
}
