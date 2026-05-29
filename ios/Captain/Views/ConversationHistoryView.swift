import SwiftUI

/// Past conversations + a "new conversation" affordance. Presented as a
/// sheet from ChatView's header. Tap a row to pin the chat surface to
/// that thread; swipe a row to delete it; tap "start a new
/// conversation" to spin one up explicitly (the backend usually creates
/// new threads automatically when the active window expires, but a
/// motivated user wants to be able to break threads on their own).
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
        NavigationStack {
            content
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && conversations.isEmpty {
            ProgressView().tint(CaptainTheme.brass)
        } else if conversations.isEmpty {
            VStack(spacing: 8) {
                Text("No past conversations yet")
                    .font(CaptainTheme.body(15))
                    .foregroundStyle(CaptainTheme.textMuted)
                Text("Your current thread will appear here once you've had a chat.")
                    .font(CaptainTheme.body(13))
                    .foregroundStyle(CaptainTheme.textMuted.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        } else {
            List {
                Section {
                    Button {
                        Task { await createAndPick() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(CaptainTheme.brass)
                            Text("Start a new conversation")
                                .foregroundStyle(CaptainTheme.textPrimary)
                            Spacer()
                            if creating {
                                ProgressView().tint(CaptainTheme.brass)
                            }
                        }
                    }
                    .disabled(creating)
                }
                Section {
                    ForEach(conversations) { convo in
                        row(convo)
                    }
                    .onDelete { offsets in
                        Task { await delete(at: offsets) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func row(_ convo: ConversationSummary) -> some View {
        Button {
            onPick(convo.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(convo.displayTitle)
                        .font(CaptainTheme.body(15, weight: .medium))
                        .foregroundStyle(CaptainTheme.textPrimary)
                        .lineLimit(2)
                    if convo.id == currentConversationId {
                        Text("current")
                            .font(CaptainTheme.body(10, weight: .semibold))
                            .foregroundStyle(CaptainTheme.brass)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(
                                    CaptainTheme.brass.opacity(0.12)
                                )
                            )
                    }
                }
                Text(convo.displayDetail)
                    .font(CaptainTheme.body(12))
                    .foregroundStyle(CaptainTheme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

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

    private func delete(at offsets: IndexSet) async {
        let victims = offsets.map { conversations[$0].id }
        // Optimistic removal so the row animates away immediately.
        conversations.remove(atOffsets: offsets)
        for id in victims {
            do {
                try await CaptainAPI.deleteConversation(id)
            } catch {
                self.error = "Delete failed: \(error.localizedDescription)"
                // Reload to recover the row if the server rejected.
                await load()
                return
            }
        }
    }
}

#Preview {
    ConversationHistoryView(
        currentConversationId: 2,
        onPick: { _ in }
    )
}
