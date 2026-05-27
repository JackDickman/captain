import Foundation

/// One stop on the scavenger hunt. The backend owns the catalog; iOS
/// only renders what `GET /hunt` returns (which is already filtered to
/// items applicable to this home's branch answers).
struct HuntItem: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let description: String
    let whereToLook: String?
    let hasPhoto: Bool
    let questionPrompt: String?
    let placeholder: String?
    let status: String          // pending | done | skipped | not_applicable
    let notes: String?
    let photoUrl: String?
    let completedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, category, description
        case whereToLook = "where_to_look"
        case hasPhoto = "has_photo"
        case questionPrompt = "question_prompt"
        case placeholder, status, notes
        case photoUrl = "photo_url"
        case completedAt = "completed_at"
    }
}

/// Top-level response from /hunt + every mutation endpoint. iOS always
/// receives the full state back so it can re-render without a separate
/// refetch.
struct HuntResponse: Codable, Equatable {
    let items: [HuntItem]
    let total: Int
    /// Count of items with status == "done".
    let done: Int
    /// Count of items resolved one way or another (done + skipped +
    /// not_applicable). Drives the "is the hunt finished?" check.
    let resolved: Int
    /// True when every visible item has been resolved.
    let complete: Bool
}
