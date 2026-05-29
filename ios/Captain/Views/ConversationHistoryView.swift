import SwiftUI

/// Past conversations + a "start a new conversation" affordance.
/// Presented as a sheet from ChatView's header. Tap a row to pin the
/// chat surface to that thread; swipe a row to delete it; tap "start a
/// new conversation" to spin one up explicitly.
///
/// Design notes:
///   - Cream background + custom serif header + brass accents so the
///     sheet reads as part of Captain, not stock iOS Settings.
///   - "Start a new conversation" is given primary-action weight
///     (filled walnut card) because that's the most likely reason a
///     user opens this surface mid-thread.
///   - History rows are creamDeep cards that match the home-screen
///     widget chrome — the same family the user sees everywhere else.
struct ConversationHistoryView: View {
    /// The thread the chat surface is currently pinned to — used to
    /// mark its row with a small "current" pill so users don't pick
    /// it back into itself.
    let currentConversationId: Int?
    /// Invoked with the chosen conversation id (or a new one from
    /// "start a new conversation"). ChatView pins to it and reloads.
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var conversations: [ConversationSummary] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        ZStack {
            CaptainTheme.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
        }
        .task { await load() }
    }

    // MARK: - Header

    /// Matches ChatView + ProfileView header pattern: chevron-down on the
    /// left, serif title, Done-action absent (the chevron is the dismiss).
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
            Text("history")
                .font(CaptainTheme.display(17))
                .foregroundStyle(CaptainTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && conversations.isEmpty {
            Spacer()
            ProgressView().tint(CaptainTheme.brass)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    newConversationCard
                    if conversations.isEmpty {
                        emptyState
                    } else {
                        sectionLabel("past conversations")
                        VStack(spacing: 10) {
                            ForEach(conversations) { convo in
                                row(convo)
                            }
                        }
                    }
                    if let error {
                        Text(error)
                            .font(CaptainTheme.body(12))
                            .foregroundStyle(CaptainTheme.rust)
                            .padding(.top, 4)
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
        }
    }

    // MARK: - New conversation primary card

    /// The reason most users open this sheet mid-thread: they want a
    /// fresh thread. Walnut fill + brass border gives it the same
    /// register as the chat capsule on the home screen, so the
    /// "primary action" reading is immediate.
    private var newConversationCard: some View {
        Button {
            Task { await createAndPick() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(CaptainTheme.brassBright)
                Text("Start a new conversation")
                    .font(CaptainTheme.body(15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                if creating {
                    ProgressView()
                        .tint(CaptainTheme.brassBright)
                        .scaleEffect(0.85)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(CaptainTheme.walnut)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                CaptainTheme.brass.opacity(0.6),
                                lineWidth: 1
                            )
                    )
            )
            .mcmShadow(intensity: 0.6)
        }
        .buttonStyle(.plain)
        .disabled(creating)
    }

    // MARK: - Section label

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(CaptainTheme.label(10))
            .foregroundStyle(CaptainTheme.textMuted)
            .tracking(1.0)
            .textCase(.uppercase)
            .padding(.top, 8)
            .padding(.leading, 4)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 26))
                .foregroundStyle(CaptainTheme.brass.opacity(0.7))
            Text("no past conversations yet")
                .font(CaptainTheme.body(14))
                .foregroundStyle(CaptainTheme.textMuted)
            Text("Captain will keep a quiet record of every chat you have here.")
                .font(CaptainTheme.body(12))
                .foregroundStyle(CaptainTheme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }

    // MARK: - Row

    /// Conversation row — creamDeep card matching the home-screen widget
    /// family. Swipe-to-delete is provided via a context-menu fallback
    /// (`.contextMenu`) since `List`-style swipes aren't available in a
    /// plain ScrollView; the long-press context menu is the iOS-native
    /// alternative and avoids dragging the user back into stock List
    /// chrome just for that one gesture.
    private func row(_ convo: ConversationSummary) -> some View {
        Button {
            onPick(convo.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(convo.displayTitle)
                            .font(CaptainTheme.body(15, weight: .medium))
                            .foregroundStyle(CaptainTheme.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if convo.id == currentConversationId {
                            currentPill
                        }
                    }
                    Text(convo.displayDetail)
                        .font(CaptainTheme.body(12))
                        .foregroundStyle(CaptainTheme.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CaptainTheme.brass.opacity(0.7))
                    .padding(.top, 4)
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
                                CaptainTheme.brass.opacity(0.3),
                                lineWidth: 1
                            )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await delete(convo) }
            } label: {
                Label("Delete conversation", systemImage: "trash")
            }
        }
    }

    private var currentPill: some View {
        Text("current")
            .font(CaptainTheme.body(10, weight: .semibold))
            .foregroundStyle(CaptainTheme.brass)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(CaptainTheme.brass.opacity(0.12))
            )
    }

    // MARK: - Network

    private func load() async {
        defer { isLoading = false }
        do {
            conversations = try await CaptainAPI.fetchConversations()
        } catch {
            self.error = "Couldn't load history: \(error.localizedDescription)"
        }
    }

    private func createAndPick() async {
        guard !creating else { return }
        creating = true
        defer { creating = false }
        do {
            let new = try await CaptainAPI.createConversation()
            onPick(new.id)
        } catch {
            self.error = "Couldn't start a new conversation: \(error.localizedDescription)"
        }
    }

    /// Single-row delete via context menu. Optimistic; on failure refetch
    /// to restore the row.
    private func delete(_ convo: ConversationSummary) async {
        conversations.removeAll { $0.id == convo.id }
        do {
            try await CaptainAPI.deleteConversation(convo.id)
        } catch {
            self.error = "Delete failed: \(error.localizedDescription)"
            await load()
        }
    }
}

#Preview {
    ConversationHistoryView(
        currentConversationId: 2,
        onPick: { _ in }
    )
}
