import Foundation

/// What the home-screen radar surfaces. Calendar items come straight from
/// the DB; suggestions are LLM-generated and cached server-side. Both are
/// returned in one shot via GET /radar.
struct RadarResponse: Codable, Equatable {
    let calendarItems: [CalendarEntry]
    let suggestions: [RadarSuggestion]
    let generatedAt: Double

    enum CodingKeys: String, CodingKey {
        case calendarItems = "calendar_items"
        case suggestions
        case generatedAt = "generated_at"
    }
}

/// One AI-generated suggestion. Identity is the title+category since the
/// LLM doesn't assign stable ids across cache refreshes.
struct RadarSuggestion: Codable, Equatable, Identifiable, Hashable {
    let title: String
    let reason: String
    let timeframe: String
    let category: String   // exterior | interior | landscaping | systems | seasonal | followup

    var id: String { "\(category)|\(title)" }
}
