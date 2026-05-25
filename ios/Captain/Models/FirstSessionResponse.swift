import Foundation

/// Initial response from POST /first-session. Either it's a fixture-mode
/// "done with inline result" envelope, or it's an async kickoff with a
/// `job_id` we'll poll on. iOS treats `result` being present as
/// "no polling needed".
struct FirstSessionKickoff: Codable {
    let jobId: String?
    let status: String
    let stage: String?
    let message: String?
    let result: FirstSessionResponse?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status, stage, message, result
    }
}

/// Response from GET /first-session/{job_id} — polling for stage updates.
struct FirstSessionStatus: Codable {
    let jobId: String
    let status: String   // "running" | "done" | "error"
    let stage: String
    let message: String
    let result: FirstSessionResponse?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status, stage, message, result, error
    }
}

/// What the backend ultimately returns once the first-session job
/// completes. Matches backend/app.py's `result` payload.
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
