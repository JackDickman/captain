import Foundation

/// Everything the profile drawer surfaces. Backed by GET /profile.
struct ProfileResponse: Codable, Equatable {
    let address: String?
    let homeMd: String
    let userMd: String
    let calendar: [CalendarEntry]

    enum CodingKeys: String, CodingKey {
        case address
        case homeMd = "home_md"
        case userMd = "user_md"
        case calendar
    }
}

/// One calendar entry. Mirrors backend's `calendar_entries` table.
struct CalendarEntry: Codable, Equatable, Identifiable, Hashable {
    let id: Int
    let text: String
    let occurredAt: String?   // ISO YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS
    let kind: String          // past | future | recurring | observation
    let source: String        // chat | first-session | manual
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, text, kind, source
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
    }
}
