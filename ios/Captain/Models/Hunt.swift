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
    /// Where the pre-fill came from when the item is pending but has
    /// notes already: "documents" (extracted from uploaded inspection
    /// report / disclosure / closing docs) or nil (user-entered or
    /// brand new). Used to render a small "from your docs" badge.
    let notesSource: String?
    /// When the user's home.md already contains something matching this
    /// item's keywords, the backend includes a short snippet of context
    /// here. iOS shows it as "Captain seems to know this already —
    /// confirm or update?" so the user doesn't redo work the profile
    /// already covers.
    let profileHint: String?
    let photoUrl: String?
    let completedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, title, category, description
        case whereToLook = "where_to_look"
        case hasPhoto = "has_photo"
        case questionPrompt = "question_prompt"
        case placeholder, status, notes
        case notesSource = "notes_source"
        case profileHint = "profile_hint"
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
    /// Count of items that came back pre-filled from uploaded documents
    /// (notes_source == "documents") and are still pending user
    /// confirmation. Surfaced on the docs banner.
    let prefilled: Int?
    /// True when every visible item has been resolved.
    let complete: Bool
    /// Only populated on the /hunt/documents response: how many photos
    /// the LLM looked at vs. how many extractions it could apply.
    /// nil on the regular /hunt fetch.
    let docsProcessed: Int?
    let docsApplied: Int?

    enum CodingKeys: String, CodingKey {
        case items, total, done, resolved, prefilled, complete
        case docsProcessed = "docs_processed"
        case docsApplied = "docs_applied"
    }
}
