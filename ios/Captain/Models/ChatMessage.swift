import Foundation

/// One message in the chat. Mirrors the row in backend's `messages` table.
struct ChatMessage: Codable, Equatable, Identifiable, Hashable {
    let id: Int
    let role: Role
    let content: String
    /// Server-relative URLs of any attached photos. Empty (or omitted) for
    /// text-only messages. Order matches the order the user attached them.
    let imageUrls: [String]?
    let createdAt: Double

    enum Role: String, Codable {
        case user
        case assistant
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case imageUrls = "image_urls"
        case createdAt = "created_at"
    }
}

/// Response from POST /chat.
struct ChatResponse: Codable {
    let messageId: Int
    let response: String
    /// Echoed back when the request included photos.
    let imageUrls: [String]?
    let fixture: Bool?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case response
        case imageUrls = "image_urls"
        case fixture
    }
}

/// Response from GET /messages.
struct MessagesResponse: Codable {
    let messages: [ChatMessage]
}
