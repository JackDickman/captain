import SwiftUI

/// The scavenger hunt list — Captain's opt-in guided tour through the
/// home. Items are grouped by category and show status pills; tapping
/// an item opens HuntItemView for the focused per-item flow.
///
/// Branch-question items live at the top (category "About your home")
/// and unlock conditional items below as the user answers them. Items
/// hidden by show_if rules don't even appear here — the backend filters
/// before sending.
struct HuntView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var response: HuntResponse?
    @State private var loadError: String?
    @State private var presentedItem: HuntItem?
    @State private var showingDocsUpload = false
    /// One-time docs-upload summary shown after the LLM extraction
    /// returns — e.g. "Pulled 7 answers from your docs". Cleared on
    /// dismiss / next refresh.
    @State private var docsToastMessage: String?

    var body: some View {
        ZStack {
            CaptainTheme.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let response {
                    progressBlock(response)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if shouldShowDocsBanner(response) {
                                docsBanner(response)
                            }
                            if let docsToastMessage {
                                toastCard(docsToastMessage)
                            }
                            ForEach(groupedCategories(response.items), id: \.self) {
                                category in
                                categorySection(
                                    category,
                                    items: response.items.filter {
                                        $0.category == category
                                    },
                                )
                            }
                            Color.clear.frame(height: 24)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                    }
                } else if let loadError {
                    Spacer()
                    Text(loadError)
                        .font(CaptainTheme.body(13))
                        .foregroundStyle(CaptainTheme.rust)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                } else {
                    Spacer()
                    ProgressView().tint(CaptainTheme.brass)
                    Spacer()
                }
            }
        }
        .task { await load() }
        .sheet(item: $presentedItem) { item in
            HuntItemView(item: item) { updated in
                response = updated
            }
        }
        .sheet(isPresented: $showingDocsUpload) {
            HuntDocumentsView { updated in
                response = updated
                let applied = updated.docsApplied ?? 0
                if applied > 0 {
                    docsToastMessage = (
                        "Pulled \(applied) "
                        + (applied == 1 ? "answer" : "answers")
                        + " from your docs — review them below."
                    )
                } else if (updated.docsProcessed ?? 0) > 0 {
                    docsToastMessage = (
                        "Couldn't pull anything new from those docs. "
                        + "No problem — you can fill items in manually."
                    )
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

            Text("the tour")
                .font(CaptainTheme.display(17))
                .foregroundStyle(CaptainTheme.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CaptainTheme.cream)
    }

    // MARK: - Progress

    private func progressBlock(_ r: HuntResponse) -> some View {
        let fraction = r.total > 0 ? Double(r.resolved) / Double(r.total) : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(progressLead(r))
                    .font(CaptainTheme.body(14))
                    .foregroundStyle(CaptainTheme.textPrimary)
                Spacer()
                Text("\(r.resolved) of \(r.total)")
                    .font(CaptainTheme.body(12, weight: .semibold))
                    .foregroundStyle(CaptainTheme.textMuted)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(CaptainTheme.creamDeep)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(CaptainTheme.brass)
                        .frame(width: proxy.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func progressLead(_ r: HuntResponse) -> String {
        if r.complete { return "All set — Captain knows your home." }
        if r.resolved == 0 { return "Captain wants to learn your home." }
        return "Picking up where you left off."
    }

    // MARK: - Documents

    /// Show the docs-upload banner when the user hasn't engaged yet —
    /// no items resolved AND no items pre-filled from a prior upload.
    /// Once anything's been done or pre-filled, the banner steps aside.
    private func shouldShowDocsBanner(_ r: HuntResponse) -> Bool {
        if r.resolved > 0 { return false }
        if (r.prefilled ?? 0) > 0 { return false }
        return true
    }

    private func docsBanner(_ r: HuntResponse) -> some View {
        Button {
            showingDocsUpload = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 18))
                    .foregroundStyle(CaptainTheme.brass)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Got docs from buying the home?")
                        .font(CaptainTheme.body(14, weight: .medium))
                        .foregroundStyle(CaptainTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(
                        "Inspection report, disclosure, closing docs — "
                        + "Captain skims them and pre-fills what it can."
                    )
                        .font(CaptainTheme.body(12))
                        .foregroundStyle(CaptainTheme.textMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CaptainTheme.brass)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(CaptainTheme.creamDeep.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                CaptainTheme.brass.opacity(0.5),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func toastCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(CaptainTheme.brass)
                .padding(.top, 2)
            Text(text)
                .font(CaptainTheme.body(13))
                .foregroundStyle(CaptainTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                docsToastMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CaptainTheme.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CaptainTheme.creamDeep.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.4), lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Categories

    private func groupedCategories(_ items: [HuntItem]) -> [String] {
        // Preserve catalog order — items already arrive in the right
        // order from the backend, so dedupe by first-seen.
        var seen: [String] = []
        for i in items where !seen.contains(i.category) {
            seen.append(i.category)
        }
        return seen
    }

    private func categorySection(_ category: String, items: [HuntItem])
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Text(category)
                .font(CaptainTheme.label(11))
                .foregroundStyle(CaptainTheme.textMuted)
                .tracking(1.2)
                .textCase(.uppercase)
            VStack(spacing: 8) {
                ForEach(items) { item in
                    Button { presentedItem = item } label: {
                        itemRow(item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func itemRow(_ item: HuntItem) -> some View {
        HStack(spacing: 12) {
            statusIcon(item.status)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(CaptainTheme.body(15, weight: .medium))
                        .foregroundStyle(rowTextColor(item.status))
                        .multilineTextAlignment(.leading)
                    rowBadge(item)
                }
                Text(item.description)
                    .font(CaptainTheme.body(12))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CaptainTheme.brass.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(rowBackground(item.status))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.25),
                            lineWidth: 1
                        )
                )
        )
    }

    /// Small pill rendered next to an item's title when there's a hint
    /// the user should know — pre-fill from docs, or a match Captain
    /// found in the home profile. Done items have no badge (the status
    /// icon carries that already).
    @ViewBuilder
    private func rowBadge(_ item: HuntItem) -> some View {
        if item.status == "pending" && item.notesSource == "documents" {
            badgeLabel("from your docs", icon: "doc.text")
        } else if item.status == "pending" && item.profileHint != nil {
            badgeLabel("already known", icon: "sparkles")
        }
    }

    private func badgeLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(CaptainTheme.body(9, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
        }
        .foregroundStyle(CaptainTheme.brass)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(CaptainTheme.brass.opacity(0.12))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.4),
                            lineWidth: 0.5
                        )
                )
        )
    }

    @ViewBuilder
    private func statusIcon(_ status: String) -> some View {
        switch status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(CaptainTheme.brass)
        case "skipped":
            Image(systemName: "arrow.uturn.right.circle")
                .font(.system(size: 20))
                .foregroundStyle(CaptainTheme.textMuted.opacity(0.7))
        case "not_applicable":
            Image(systemName: "minus.circle")
                .font(.system(size: 20))
                .foregroundStyle(CaptainTheme.textMuted.opacity(0.7))
        default:
            Image(systemName: "circle")
                .font(.system(size: 20))
                .foregroundStyle(CaptainTheme.brass.opacity(0.5))
        }
    }

    private func rowTextColor(_ status: String) -> Color {
        switch status {
        case "done": return CaptainTheme.textPrimary
        case "skipped", "not_applicable": return CaptainTheme.textMuted
        default: return CaptainTheme.textPrimary
        }
    }

    private func rowBackground(_ status: String) -> Color {
        switch status {
        case "done": return CaptainTheme.creamDeep.opacity(0.7)
        default: return CaptainTheme.creamDeep.opacity(0.45)
        }
    }

    // MARK: - Network

    private func load() async {
        do {
            response = try await CaptainAPI.fetchHunt()
        } catch {
            loadError = "Couldn't load the tour: \(error.localizedDescription)"
        }
    }
}

#Preview {
    HuntView()
}
