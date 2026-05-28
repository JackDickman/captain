import Foundation

/// One quiet "on this day" recall line for the home screen — Captain
/// speaking unbidden (PRD §6.7). `recall` is null on most days; the iOS
/// surface renders nothing when null. Cached server-side for 24h.
struct BiographerResponse: Codable, Equatable {
    let recall: BiographerRecall?
}

struct BiographerRecall: Codable, Equatable, Hashable {
    /// The short line Captain says, e.g. "A year ago today, you noticed
    /// the lilacs were about to bloom."
    let text: String
    /// ISO date string of the source calendar entry (debug / accessibility).
    let occurredAt: String?
    /// Original calendar entry text — kept so a future surface can let
    /// the user tap through to see the underlying memory.
    let entryText: String?

    enum CodingKeys: String, CodingKey {
        case text
        case occurredAt = "occurred_at"
        case entryText = "entry_text"
    }
}
