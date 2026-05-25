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

        var errorDescription: String? {
            switch self {
            case let .badStatus(code, body):
                return "Backend returned HTTP \(code): \(body.prefix(200))"
            case let .decoding(err):
                return "Couldn't decode backend response: \(err.localizedDescription)"
            }
        }
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
    /// Fixture mode bypasses polling: the kickoff response carries the
    /// inline `result` and we return it immediately.
    static func firstSession(
        photo: Data,
        photoFilename: String,
        address: String,
        progress: @MainActor @escaping (String) -> Void = { _ in }
    ) async throws -> FirstSessionResponse {
        let kickoff = try await postFirstSessionKickoff(
            photo: photo, photoFilename: photoFilename, address: address,
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
                throw APIError.badStatus(500, status.error ?? "unknown error")
            default:
                continue  // still running
            }
        }
        throw CancellationError()
    }

    /// Multipart POST kickoff. Returns the kickoff envelope without blocking.
    private static func postFirstSessionKickoff(
        photo: Data, photoFilename: String, address: String,
    ) async throws -> FirstSessionKickoff {
        let url = baseURL.appendingPathComponent("first-session")
        let boundary = "Boundary-\(UUID().uuidString)"
        let compressed = compressForUpload(photo)

        var request = URLRequest(url: url)
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
        appendString("--\(boundary)\r\n")
        appendString(
            "Content-Disposition: form-data; name=\"photo\"; " +
            "filename=\"\(photoFilename)\"\r\n"
        )
        appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(compressed)
        appendString("\r\n--\(boundary)--\r\n")
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
        var request = URLRequest(url: url)
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
    static func renderingURL(for relativePath: String) -> URL {
        let trimmed = relativePath.hasPrefix("/")
            ? String(relativePath.dropFirst())
            : relativePath
        return baseURL.appendingPathComponent(trimmed)
    }

    // MARK: - Chat

    /// POST /chat (multipart). Text-only or with one-or-more attached
    /// photos. Multiple photos are sent as repeated `photos` fields.
    static func sendChatMessage(
        _ text: String,
        photos: [Data] = []
    ) async throws -> ChatResponse {
        let url = baseURL.appendingPathComponent("chat")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        // Chat is fast (~2-5s) text-only; vision adds a few seconds per
        // photo. Generous timeout so a multi-photo message doesn't die.
        request.timeoutInterval = 180

        var body = Data()
        func appendString(_ s: String) {
            body.append(s.data(using: .utf8)!)
        }
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"message\"\r\n\r\n")
        appendString("\(text)\r\n")

        for (i, photo) in photos.enumerated() {
            // Compress so each upload + vision call stays snappy.
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
            return try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// GET /profile — home + owner markdown profiles + full calendar.
    /// Used by ProfileView (the corner-avatar drawer).
    static func fetchProfile() async throws -> ProfileResponse {
        let url = baseURL.appendingPathComponent("profile")
        let (data, response) = try await URLSession.shared.data(from: url)
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
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.badStatus(code, "")
        }
        return try JSONDecoder()
            .decode(WeatherResponse.self, from: data).periods
    }

    /// GET /messages — full conversation history. Used to hydrate the chat
    /// view on launch / when ChatView first appears.
    static func fetchMessages() async throws -> [ChatMessage] {
        let url = baseURL.appendingPathComponent("messages")
        let (data, response) = try await URLSession.shared.data(from: url)
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
