import Foundation

/// One product Captain recommends in chat. Attached to an assistant
/// message when the model invokes `find_products` with num_options >= 2
/// (the user sees these as compact cards under the bubble text). When
/// num_options == 1, the link is embedded inline in the prose instead
/// and no ProductPick is created.
struct ProductPick: Codable, Equatable, Hashable {
    /// Display title of the product (typically the Amazon listing title).
    let title: String
    /// Where to buy. v1 is "Amazon"; structure leaves room for Home
    /// Depot / Lowe's / etc. without breaking the wire format.
    let retailer: String
    /// Affiliate-tagged URL the user opens. Captain wraps Amazon URLs
    /// with the configured affiliate tag server-side.
    let url: String
    /// Short blurb extracted from the listing — shown on the card.
    let blurb: String
}

/// One message in the chat. Mirrors the row in backend's `messages` table.
struct ChatMessage: Codable, Equatable, Identifiable, Hashable {
    let id: Int
    let role: Role
    let content: String
    /// Server-relative URLs of any attached photos. Empty (or omitted) for
    /// text-only messages. Order matches the order the user attached them.
    let imageUrls: [String]?
    /// Product cards Captain attached to an assistant message via the
    /// find_products tool. Empty / nil on user messages and on assistant
    /// messages where the model chose num_options=1 (embedded inline).
    let productPicks: [ProductPick]?
    /// Web-search queries Captain ran during this assistant turn (in
    /// order). Persisted so the "searched the web for X" badge re-renders
    /// after a chat reload, not just immediately after the send.
    let searches: [String]?
    let createdAt: Double

    enum Role: String, Codable {
        case user
        case assistant
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case imageUrls = "image_urls"
        case productPicks = "product_picks"
        case searches
        case createdAt = "created_at"
    }
}

/// The final payload from a completed chat turn. Reached either inline
/// (fixture mode / scope-gated canned replies) or after polling
/// /chat/{chat_id} until done.
struct ChatResponse: Codable {
    let messageId: Int
    let response: String
    /// Echoed back when the request included photos.
    let imageUrls: [String]?
    let fixture: Bool?
    /// Search queries Captain ran during this turn (in order). Used to
    /// show a "🌐 searched the web for X" footer on the assistant bubble
    /// so the user can see what was looked up.
    let searches: [String]?
    /// Product cards Captain attached this turn. Same data as
    /// ChatMessage.productPicks — duplicated here for the optimistic
    /// path so cards can render the instant the response arrives,
    /// before the full message history refetch.
    let productPicks: [ProductPick]?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case response
        case imageUrls = "image_urls"
        case fixture
        case searches
        case productPicks = "product_picks"
    }
}

/// Initial response from POST /chat. Either an inline `result` (fixture
/// mode or a scope-gated canned reply) or an async kickoff with a
/// `chatId` we'll poll on. iOS treats `result` being present as
/// "no polling needed."
struct ChatKickoff: Codable {
    let chatId: String?
    let status: String
    let stage: String?
    let result: ChatResponse?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case status, stage, result
    }
}

/// Response from GET /chat/{chat_id} — polling for stage updates.
struct ChatStatus: Codable {
    let chatId: String
    let status: String          // "running" | "done" | "error"
    let stage: String?          // "thinking" | "searching" | "writing" | "done"
    let stageLabel: String?
    let searchQuery: String?    // populated when stage == "searching"
    let result: ChatResponse?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case status, stage, result, error
        case stageLabel = "stage_label"
        case searchQuery = "search_query"
    }
}

/// Response from GET /messages.
struct MessagesResponse: Codable {
    let messages: [ChatMessage]
}
