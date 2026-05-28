import Foundation
import SwiftUI

/// Top-level app state: holds the captured first-session result and persists
/// it across launches via UserDefaults. Will move to a real local store
/// (SwiftData or Core Data) when we add chat history + calendar entries.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var firstSession: FirstSessionResponse?

    private let storageKey = "captain.firstSession.v1"

    init() {
        // Debug affordance: launching with `--load-fixture` skips first-session
        // and pre-populates AppState with the Silsby canned data. Used for
        // screenshots and rapid UI iteration. Requires the backend to also be
        // running in CAPTAIN_DEV_FIXTURE=1 mode so the rendering URL resolves.
        if ProcessInfo.processInfo.arguments.contains("--load-fixture") {
            firstSession = FirstSessionResponse(
                jobId: "dev-fixture",
                address: "4221 Silsby Rd, University Heights, OH 44118",
                currentSeason: "spring",
                currentRenderingUrl: "/rendered/fixture-silsby/spring.png",
                renderings: [:],
                palette: [
                    "#b22222", "#ffffff", "#a9a9a9",
                    "#d2b48c", "#000000", "#ffd700",
                ],
                features: [],
                sourceUrls: [],
                fixture: true
            )
            return
        }
        load()
    }

    func setFirstSession(_ response: FirstSessionResponse) {
        firstSession = response
        save()
    }

    func reset() {
        firstSession = nil
        UserDefaults.standard.removeObject(forKey: storageKey)
        // Re-arm gesture hints so a re-onboarded user sees them again.
        GestureHint.resetAll()
    }

    private func save() {
        guard let firstSession,
              let data = try? JSONEncoder().encode(firstSession) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                FirstSessionResponse.self, from: data
              ) else { return }
        firstSession = decoded
    }
}
