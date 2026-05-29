import Foundation

/// One row in the chat-history list (PRD §6.5 conversation history). A
/// brand-new conversation has a null `title` (the background titler
/// runs after the first exchange) — iOS falls back to a derived label
/// from `firstUserText` or the creation date.
struct ConversationSummary: Codable, Equatable, Identifiable, Hashable {
    let id: Int
    /// LLM-generated short label like "wax ring on the upstairs toilet".
    /// Null on brand-new threads; renderable code should fall back to
    /// derived labels — see `displayTitle` below.
    let title: String?
    /// Unix epoch (server clock) when the conversation row was created.
    let createdAt: Double
    /// Unix epoch of the most recent message in this conversation, or
    /// nil if no messages have been added yet.
    let lastMessageAt: Double?
    /// How many messages live under this conversation, both user and
    /// assistant. Shown as a small counter on the history row.
    let messageCount: Int
    /// The first user message's content, truncated by the server. Used
    /// as a preview line + as the title fallback when no title exists.
    let firstUserText: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
        case messageCount = "message_count"
        case firstUserText = "first_user_text"
    }

    /// What to show on the history row's first line. Prefers the
    /// LLM-generated title, falls back to a truncated first user
    /// message, and finally to a date label for truly empty threads.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let text = firstUserText, !text.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(60))
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: createdAt))
    }

    /// A short "X messages · 3h ago" style detail line for the row.
    var displayDetail: String {
        let when = Date(
            timeIntervalSince1970: lastMessageAt ?? createdAt
        )
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        let relative = rel.localizedString(for: when, relativeTo: Date())
        let count = messageCount == 1 ? "1 message" : "\(messageCount) messages"
        return "\(count) · \(relative)"
    }
}

/// Wrapper for GET /conversations.
struct ConversationListResponse: Codable {
    let conversations: [ConversationSummary]
}
