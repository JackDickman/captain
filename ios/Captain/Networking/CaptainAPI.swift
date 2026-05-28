import Foundation
import UIKit

/// Minimal client for the local dev backend. Real production base URL goes
/// in here later when we deploy.
enum CaptainAPI {
    /// localhost reachable from the iOS Simulator (which shares the Mac's
    /// network). When testing on a physical device on the same LAN, swap
    /// this for the Mac's IP (e.g. http://192.168.x.x:8000).
    static let baseURL = URL(string: "http://localhost:8000")!

    enum APIError: Error, LocalizedError {
        case badStatus(Int, String)
        case decoding(Error)
        /// User-facing validation error from the backend (bad photo / bad
        /// address during first-session). Surfaced verbatim — no HTTP
        /// chrome — because the message was already written for users.
        case userMessage(String)

        var errorDescription: String? {
            switch self {
            case let .badStatus(code, body):
                return "Backend returned HTTP \(code): \(body.prefix(200))"
            case let .decoding(err):
                return "Couldn't decode backend response: \(err.localizedDescription)"
            case let .userMessage(message):
                return message
            }
        }
    }

    /// Build a URLRequest with the `X-Captain-Local-Time` header pre-set
    /// so any backend endpoint that injects "today" or "local time" into
    /// LLM prompts (chat, radar, calendar extraction) can ground against
    /// the user's clock instead of the server's. Falls back gracefully:
    /// if the header is missing or malformed on the backend side, it
    /// uses server-local time. ISO 8601 with offset ("…-04:00" / "…Z")
    /// is parsed correctly by Python's datetime.fromisoformat.
    private static func makeRequest(url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(
            localTimeString(), forHTTPHeaderField: "X-Captain-Local-Time"
        )
        return r
    }

    /// Current device-local time as an ISO 8601 string including the
    /// UTC offset (e.g. "2026-05-26T14:15:00-04:00"). Recomputed every
    /// call so a long-running app session always sends fresh values.
    private static func localTimeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: Date())
    }

    /// Resize + re-encode an original photo to something the backend can
    /// process quickly. Original iPhone JPEGs are 5-10 MB; the LLM image
    /// endpoints don't benefit from anything beyond ~1500px on the long edge
    /// and the upload over localhost was hitting CFNetwork failure modes
    /// (request_duration_ms=87000+ for a 7 MB body, response_bytes=0). A
    /// compact JPEG uploads in milliseconds and avoids the issue entirely.
    private static func compressForUpload(_ data: Data, maxDim: CGFloat = 1600,
                                          jpegQuality: CGFloat = 0.85) -> Data {
        guard let img = UIImage(data: data) else { return data }
        let scale = min(1.0, maxDim / max(img.size.width, img.size.height))
        let target = CGSize(width: img.size.width * scale,
                            height: img.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // we want target px count, not @2x
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: jpegQuality) ?? data
    }

    /// POST a photo to /prerender to speculatively start the render
    /// pipeline as soon as the user picks an image. Returns a prefetch
    /// id that can later be passed to firstSession() to skip the
    /// (slowest) render stage. Silent failure on the iOS side — if the
    /// prerender call errors, firstSession() will fall back to the full
    /// photo-upload + fresh-render path.
    static func prerender(photo: Data) async throws -> String? {
        let url = baseURL.appendingPathComponent("prerender")
        let boundary = "Boundary-\(UUID().uuidString)"
        let compressed = compressForUpload(photo)

        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 30

        var body = Data()
        func appendString(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }
        appendString("--\(boundary)\r\n")
        appendString(
            "Content-Disposition: form-data; name=\"photo\"; " +
            "filename=\"photo.jpg\"\r\n"
        )
        appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(compressed)
        appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.badStatus(code, "prerender failed")
        }
        let decoded = try JSONDecoder().decode(
            PrerenderResponse.self, from: data
        )
        // skipped=true in fixture mode; treat as "no prefetch available."
        return decoded.skipped == true ? nil : decoded.prefetchId
    }

    private struct PrerenderResponse: Decodable {
        let prefetchId: String?
        let skipped: Bool?
        enum CodingKeys: String, CodingKey {
            case prefetchId = "prefetch_id"
            case skipped
        }
    }

    /// POST a photo + address to /first-session and wait for the result.
    ///
    /// Backend is now async: the POST returns immediately with a `job_id`,
    /// and we poll GET /first-session/{job_id} every second until status
    /// is "done" (carrying the full `result`) or "error".
    ///
    /// `progress` is called on the main actor with each new stage message
    /// so the loading view can show changing text ("Looking up your home
    /// in public records…" → "Painting a portrait of your home…" etc).
    ///
    /// When `prefetchId` is provided, the photo upload is skipped — the
    /// backend reuses the already-saved photo and the in-flight render
    /// (huge latency win).
    ///
    /// Fixture mode bypasses polling: the kickoff response carries the
    /// inline `result` and we return it immediately.
    static func firstSession(
        photo: Data,
        photoFilename: String,
        address: String,
        prefetchId: String? = nil,
        progress: @MainActor @escaping (String) -> Void = { _ in }
    ) async throws -> FirstSessionResponse {
        let kickoff = try await postFirstSessionKickoff(
            photo: photo, photoFilename: photoFilename, address: address,
            prefetchId: prefetchId,
        )
        if let result = kickoff.result {
            return result
        }
        guard let jobId = kickoff.jobId else {
            throw APIError.badStatus(0, "no job_id and no result")
        }
        if let initial = kickoff.message {
            await progress(initial)
        }

        let started = Date()
        let maxWait: TimeInterval = 5 * 60  // 5-min safety net
        while !Task.isCancelled {
            if Date().timeIntervalSince(started) > maxWait {
                throw APIError.badStatus(0, "first-session timed out")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let status = try await fetchFirstSessionStatus(jobId: jobId)
            await progress(status.message)
            switch status.status {
            case "done":
                if let result = status.result { return result }
                throw APIError.badStatus(200, "done but no result")
            case "error":
                // The backend's error string is user-facing (set by
                // _fail_job, which carries validation messages verbatim).
                throw APIError.userMessage(
                    status.error ?? "Something went wrong."
                )
            default:
                continue  // still running
            }
        }
        throw CancellationError()
    }

    /// Multipart POST kickoff. Returns the kickoff envelope without blocking.
    ///
    /// When `prefetchId` is given, the photo upload is omitted — the
    /// backend reuses the already-saved photo from the prior /prerender
    /// call. Cuts the upload time on real iPhone photos.
    private static func postFirstSessionKickoff(
        photo: Data, photoFilename: String, address: String,
        prefetchId: String? = nil,
    ) async throws -> FirstSessionKickoff {
        let url = baseURL.appendingPathComponent("first-session")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        // POST should return in <1s now (just kicks off the job).
        request.timeoutInterval = 30

        var body = Data()
        func appendString(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"address\"\r\n\r\n")
        appendString("\(address)\r\n")

        if let prefetchId {
            appendString("--\(boundary)\r\n")
            appendString(
                "Content-Disposition: form-data; name=\"prefetch_id\"\r\n\r\n"
            )
            appendString("\(prefetchId)\r\n")
        } else {
            let compressed = compressForUpload(photo)
            appendString("--\(boundary)\r\n")
            appendString(
                "Content-Disposition: form-data; name=\"photo\"; " +
                "filename=\"\(photoFilename)\"\r\n"
            )
            appendString("Content-Type: image/jpeg\r\n\r\n")
            body.append(compressed)
            appendString("\r\n")
        }
        appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badStatus(-1, "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw APIError.badStatus(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(FirstSessionKickoff.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Poll one tick of /first-session/{job_id}.
    private static func fetchFirstSessionStatus(
        jobId: String,
    ) async throws -> FirstSessionStatus {
        let url = baseURL.appendingPathComponent("first-session/\(jobId)")
        var request = makeRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badStatus(-1, "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw APIError.badStatus(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(FirstSessionStatus.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Build a fully-qualified URL from a server-relative rendering path.
    ///
    /// Already-absolute URLs (data:, http://, https://) are passed through
    /// unchanged — this matters for the optimistic chat-bubble flow, which
    /// renders a data: URL while the real upload is in flight before the
    /// fetched message replaces it with a `/chat-photos/...` path.
    static func renderingURL(for relativePath: String) -> URL {
        if let absolute = URL(string: relativePath),
           let scheme = absolute.scheme?.lowercased(),
           scheme == "data" || scheme == "http" || scheme == "https" {
            return absolute
        }
        let trimmed = relativePath.hasPrefix("/")
            ? String(relativePath.dropFirst())
            : relativePath
        return baseURL.appendingPathComponent(trimmed)
    }

    // MARK: - Chat

    /// What Captain is doing right now during an in-flight chat turn.
    /// Surfaced to ChatView so the "thinking" bubble can swap to a
    /// "searching the web for X" badge while a tool call is running.
    enum ChatStage: Equatable {
        case thinking
        case searching(query: String)
        case writing
    }

    /// Send a chat message and wait for Captain's response.
    ///
    /// Backend is async: the POST returns either an inline result
    /// (fixture mode or a scope-gated canned reply — no polling needed)
    /// or a chat_id we then poll on /chat/{chat_id} until status is
    /// "done" or "error". The polling carries stage updates so the iOS
    /// chat surface can show "Captain is checking the web for X…" while
    /// a tool call is in flight.
    static func sendChatMessage(
        _ text: String,
        photos: [Data] = [],
        onStage: @MainActor @escaping (ChatStage) -> Void = { _ in }
    ) async throws -> ChatResponse {
        let kickoff = try await postChatKickoff(text: text, photos: photos)
        if let result = kickoff.result {
            return result  // fixture / scope-gated path, no polling needed
        }
        guard let chatId = kickoff.chatId else {
            throw APIError.badStatus(0, "no chat_id and no result")
        }

        // Poll until done. 500ms cadence keeps stage updates feeling
        // live without flooding the backend.
        let started = Date()
        let maxWait: TimeInterval = 180
        while !Task.isCancelled {
            if Date().timeIntervalSince(started) > maxWait {
                throw APIError.badStatus(0, "chat timed out")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            let status = try await fetchChatStatus(chatId: chatId)
            // Surface the stage to the UI on every poll so the indicator
            // tracks the backend's current phase.
            if let stage = status.stage {
                let mapped: ChatStage
                switch stage {
                case "searching":
                    mapped = .searching(query: status.searchQuery ?? "")
                case "writing":
                    mapped = .writing
                default:
                    mapped = .thinking
                }
                await onStage(mapped)
            }
            switch status.status {
            case "done":
                if let result = status.result { return result }
                throw APIError.badStatus(200, "done but no result")
            case "error":
                throw APIError.userMessage(status.error ?? "Chat failed.")
            default:
                continue  // still running
            }
        }
        throw CancellationError()
    }

    /// Multipart POST to /chat. Returns the kickoff envelope — either an
    /// inline `result` (fixture, scope-gated) or just a `chat_id` we'll
    /// poll on.
    private static func postChatKickoff(
        text: String, photos: [Data],
    ) async throws -> ChatKickoff {
        let url = baseURL.appendingPathComponent("chat")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        // The kickoff POST returns fast now (sub-second) — it just spawns
        // the worker thread. Keep a comfortable timeout for the photo
        // upload itself.
        request.timeoutInterval = 60

        var body = Data()
        func appendString(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"message\"\r\n\r\n")
        appendString("\(text)\r\n")

        for (i, photo) in photos.enumerated() {
            let compressed = compressForUpload(photo, maxDim: 1280)
            appendString("--\(boundary)\r\n")
            appendString(
                "Content-Disposition: form-data; name=\"photos\"; " +
                "filename=\"chat-\(i).jpg\"\r\n"
            )
            appendString("Content-Type: image/jpeg\r\n\r\n")
            body.append(compressed)
            appendString("\r\n")
        }
        appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badStatus(-1, "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw APIError.badStatus(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(ChatKickoff.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Poll one tick of /chat/{chat_id}.
    private static func fetchChatStatus(
        chatId: String,
    ) async throws -> ChatStatus {
        let url = baseURL.appendingPathComponent("chat/\(chatId)")
        var request = makeRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badStatus(-1, "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw APIError.badStatus(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(ChatStatus.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// GET /radar — upcoming calendar items + LLM-generated suggestions.
    /// Used by RadarStrip (compact home-screen card) + RadarView (sheet).
    static func fetchRadar() async throws -> RadarResponse {
        let url = baseURL.appendingPathComponent("radar")
        var request = makeRequest(url: url)
        // LLM call on cold cache takes ~2-5s; cached is instant.
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.badStatus(code, "")
        }
        do {
            return try JSONDecoder().decode(RadarResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// POST /chat/radar-explain — kickoff message Captain sends when
    /// the user taps a radar item to learn more. Persists ONLY the
    /// assistant turn (no fabricated user message in scroll-back).
    /// Returns the persisted message id + text so the caller can show
    /// optimistically before re-fetching full history.
    static func explainRadarItem(
        itemType: String, itemText: String,
    ) async throws -> ChatResponse {
        let url = baseURL.appendingPathComponent("chat/radar-explain")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        // The chat LLM runs synchronously here; usual chat response
        // takes a few seconds, multi-image-aware Vision models can
        // take longer. Generous timeout.
        request.timeoutInterval = 120

        var body = Data()
        func appendString(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }
        appendString("--\(boundary)\r\n")
        appendString(
            "Content-Disposition: form-data; name=\"item_type\"\r\n\r\n"
        )
        appendString("\(itemType)\r\n")
        appendString("--\(boundary)\r\n")
        appendString(
            "Content-Disposition: form-data; name=\"item_text\"\r\n\r\n"
        )
        appendString("\(itemText)\r\n")
        appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw APIError.badStatus(code, body)
        }
        do {
            return try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Scavenger hunt

    /// GET /hunt — full hunt state (applicable items + progress).
    static func fetchHunt() async throws -> HuntResponse {
        let url = baseURL.appendingPathComponent("hunt")
        var request = makeRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.expectOK(response)
        do {
            return try JSONDecoder().decode(HuntResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// POST /hunt/{id} — mark an item done with optional photo + notes.
    /// Photo items require a photo; text-only items require notes.
    /// Returns the updated full state.
    static func completeHuntItem(
        _ itemId: String, notes: String, photo: Data?,
    ) async throws -> HuntResponse {
        let url = baseURL.appendingPathComponent("hunt/\(itemId)")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        // Photo extraction kicks off in the background; the foreground
        // call just persists + returns the new state, so ~1s.
        request.timeoutInterval = 60

        var body = Data()
        func appendString(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"notes\"\r\n\r\n")
        appendString("\(notes)\r\n")

        if let photo {
            let compressed = compressForUpload(photo, maxDim: 1280)
            appendString("--\(boundary)\r\n")
            appendString(
                "Content-Disposition: form-data; name=\"photo\"; " +
                "filename=\"\(itemId).jpg\"\r\n"
            )
            appendString("Content-Type: image/jpeg\r\n\r\n")
            body.append(compressed)
            appendString("\r\n")
        }
        appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.expectOK(response, data)
        do {
            return try JSONDecoder().decode(HuntResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// POST /hunt/documents — upload one or more document photos for
    /// the backend to extract pre-fill answers from. Returns the full
    /// updated hunt state (with prefilled count + docs counters).
    /// Vision extraction is slow; allow up to 120s.
    static func uploadHuntDocuments(
        _ photos: [Data],
    ) async throws -> HuntResponse {
        let url = baseURL.appendingPathComponent("hunt/documents")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        // Multi-page inspection reports + vision model = real latency.
        // Keep generous; the iOS UI shows progress while we wait.
        request.timeoutInterval = 180

        var body = Data()
        func appendString(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }
        for (i, photo) in photos.enumerated() {
            // Documents need more legibility than chat photos — keep
            // the long edge higher so dense inspection-report text
            // survives the upload.
            let compressed = compressForUpload(photo, maxDim: 2000)
            appendString("--\(boundary)\r\n")
            appendString(
                "Content-Disposition: form-data; name=\"photos\"; " +
                "filename=\"doc-\(i).jpg\"\r\n"
            )
            appendString("Content-Type: image/jpeg\r\n\r\n")
            body.append(compressed)
            appendString("\r\n")
        }
        appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.expectOK(response, data)
        do {
            return try JSONDecoder().decode(HuntResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// POST /hunt/{id}/skip — set status to skipped.
    static func skipHuntItem(_ itemId: String) async throws -> HuntResponse {
        try await huntAction(itemId, action: "skip")
    }

    /// POST /hunt/{id}/not-applicable — set status to not_applicable.
    static func huntItemNotApplicable(
        _ itemId: String,
    ) async throws -> HuntResponse {
        try await huntAction(itemId, action: "not-applicable")
    }

    /// POST /hunt/{id}/reset — move back to pending for a redo.
    static func resetHuntItem(_ itemId: String) async throws -> HuntResponse {
        try await huntAction(itemId, action: "reset")
    }

    private static func huntAction(
        _ itemId: String, action: String,
    ) async throws -> HuntResponse {
        let url = baseURL.appendingPathComponent("hunt/\(itemId)/\(action)")
        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.expectOK(response, data)
        do {
            return try JSONDecoder().decode(HuntResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Common HTTP-status check used by hunt endpoints. Bubbles a
    /// user-facing message when the backend returned a non-2xx so the
    /// hunt UI can surface it inline.
    private static func expectOK(
        _ response: URLResponse, _ data: Data? = nil,
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badStatus(-1, "no http response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
                ?? "<binary>"
            throw APIError.badStatus(http.statusCode, body)
        }
    }

    /// GET /profile — home + owner markdown profiles + full calendar.
    /// Used by ProfileView (the corner-avatar drawer).
    static func fetchProfile() async throws -> ProfileResponse {
        let url = baseURL.appendingPathComponent("profile")
        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.badStatus(code, "")
        }
        do {
            return try JSONDecoder().decode(ProfileResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// GET /weather — structured forecast for the home's location. Used by
    /// the home screen date/weather widget.
    static func fetchWeather() async throws -> [WeatherPeriod] {
        let url = baseURL.appendingPathComponent("weather")
        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.badStatus(code, "")
        }
        return try JSONDecoder()
            .decode(WeatherResponse.self, from: data).periods
    }

    /// DELETE /messages — wipe the chat scroll-back for the current home.
    /// Profile + calendar + rendering are untouched.
    static func clearMessages() async throws {
        let url = baseURL.appendingPathComponent("messages")
        var request = makeRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.badStatus(code, "clear failed")
        }
    }

    /// DELETE /calendar/{id} — remove a calendar entry the user dismisses
    /// from the profile drawer.
    static func deleteCalendarEntry(_ id: Int) async throws {
        let url = baseURL.appendingPathComponent("calendar/\(id)")
        var request = makeRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.badStatus(code, "delete failed")
        }
    }

    /// GET /messages — full conversation history. Used to hydrate the chat
    /// view on launch / when ChatView first appears.
    static func fetchMessages() async throws -> [ChatMessage] {
        let url = baseURL.appendingPathComponent("messages")
        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badStatus(-1, "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw APIError.badStatus(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(MessagesResponse.self, from: data)
                .messages
        } catch {
            throw APIError.decoding(error)
        }
    }
}
