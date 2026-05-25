import Foundation

/// What the backend returns from POST /first-session. Matches backend/app.py.
struct FirstSessionResponse: Codable, Equatable {
    let jobId: String
    let address: String
    let currentSeason: String
    let currentRenderingUrl: String  // server-relative, e.g. "/rendered/<id>/spring.png"
    let renderings: [String: String]  // season -> url
    let palette: [String]             // hex colors, e.g. "#b22222"
    let features: [HomeFeature]
    let sourceUrls: [String]
    let fixture: Bool?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case address
        case currentSeason = "current_season"
        case currentRenderingUrl = "current_rendering_url"
        case renderings
        case palette
        case features
        case sourceUrls = "source_urls"
        case fixture
    }
}

/// One open-ended fact about the home (from photo or web). The shape is loose
/// by design — see project_captain.md and the first_session.py extraction.
struct HomeFeature: Codable, Equatable, Identifiable, Hashable {
    let text: String
    let source: String   // "image" | "web" | "both"
    let category: String // free-form: "architecture", "exterior", etc.

    var id: String { "\(category)|\(source)|\(text)" }
}
