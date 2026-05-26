import SwiftUI

/// Post-first-session home screen. The rendered home is the dominant visual
/// (PRD §7.4), framed in brass like a piece of cherished art on a wall. Chat
/// bar sits below on a wood-grain "cabinetry" surface. Bottom-sheet radar
/// arrives in a later milestone.
struct HomeView: View {
    let session: FirstSessionResponse
    @EnvironmentObject var appState: AppState
    @State private var chatPresented = false
    @State private var profilePresented = false
    @State private var radarPresented = false
    @State private var weatherPeriods: [WeatherPeriod] = []
    @State private var radar: RadarResponse?
    @State private var radarLoading = true

    /// Second swatch from the home's extracted palette, used as the warm
    /// top-of-screen gradient. First swatch isn't read directly — the
    /// brass picture frame already carries the dominant accent.
    private var accent2: Color {
        Color(hex: session.palette.dropFirst().first ?? "#d8b486")
    }

    var body: some View {
        ZStack {
            background
            content
        }
        .fullScreenCover(isPresented: $chatPresented) {
            ChatView(session: session)
        }
        .sheet(isPresented: $profilePresented) {
            ProfileView(session: session)
        }
        .sheet(isPresented: $radarPresented) {
            if let radar {
                RadarView(radar: radar)
            }
        }
        .task { await loadWeather() }
        .task { await loadRadar() }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            // Debug: launch with --auto-chat / --show-profile to open the
            // corresponding sheet immediately (used for screenshots).
            if args.contains("--auto-chat") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    chatPresented = true
                }
            }
            if args.contains("--show-profile") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    profilePresented = true
                }
            }
        }
    }

    private func loadWeather() async {
        if let periods = try? await CaptainAPI.fetchWeather() {
            weatherPeriods = periods
        }
    }

    private func loadRadar() async {
        radarLoading = true
        defer { radarLoading = false }
        if let result = try? await CaptainAPI.fetchRadar() {
            radar = result
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            CaptainTheme.cream
            // Soft warm glow from the home's own palette
            LinearGradient(
                colors: [accent2.opacity(0.20), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBlock
            Spacer().frame(height: 18)
            heroImage
            Spacer().frame(height: 14)
            WeatherWidget(periods: weatherPeriods)
                .padding(.horizontal, 24)
            Spacer().frame(height: 10)
            RadarStrip(radar: radar, isLoading: radarLoading) {
                if radar != nil { radarPresented = true }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 12)
            // Bottom chat capsule sits inline in the column now (no walnut
            // surface beneath it) — the cream background runs unbroken
            // from the home image all the way to the safe area.
            chatCapsule
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }

    /// First comma-separated component of the address — the user knows
    /// their full address; the home screen only needs the street identifier.
    private var shortAddress: String {
        session.address
            .split(separator: ",", maxSplits: 1)
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            ?? session.address
    }

    /// Today's date, formatted as "Sunday, May 24" — sits to the right of
    /// the address as a quiet timestamp on the home screen.
    private var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"  // "Sun, May 24"
        return f.string(from: Date())
    }

    /// The home screen's top row. Left: greeting (welcome home + address).
    /// Right: today's date + the profile-drawer avatar, on the same line,
    /// vertically centered with the greeting's 2-line column.
    private var topBlock: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("welcome home")
                    .font(CaptainTheme.body(13))
                    .foregroundStyle(CaptainTheme.textMuted)
                Text(shortAddress)
                    .font(CaptainTheme.display(18))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Text(todayString)
                .font(CaptainTheme.body(13))
                .foregroundStyle(CaptainTheme.textMuted)
                .lineLimit(1)
            Button {
                profilePresented = true
            } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(CaptainTheme.brass)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(CaptainTheme.creamDeep.opacity(0.6)))
                    .overlay(
                        Circle().strokeBorder(
                            CaptainTheme.brass.opacity(0.4),
                            lineWidth: 1
                        )
                    )
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        // Debug: long-press the row to reset the first session and start over.
        .onLongPressGesture(minimumDuration: 1.0) {
            appState.reset()
        }
    }

    private var heroImage: some View {
        AsyncImage(
            url: CaptainAPI.renderingURL(for: session.currentRenderingUrl)
        ) { phase in
            switch phase {
            case .empty:
                RoundedRectangle(cornerRadius: 12)
                    .fill(CaptainTheme.creamDeep)
                    .overlay(
                        ProgressView().tint(CaptainTheme.brass)
                    )
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                RoundedRectangle(cornerRadius: 12)
                    .fill(CaptainTheme.rust.opacity(0.08))
                    .overlay(
                        Text("couldn't load home image")
                            .font(CaptainTheme.body(12))
                            .foregroundStyle(CaptainTheme.rust)
                    )
            @unknown default:
                EmptyView()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Brass picture frame — echoes the framed sunflowers reference
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(CaptainTheme.brass, lineWidth: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(CaptainTheme.brassBright.opacity(0.6), lineWidth: 1)
                .padding(2)
        )
        .mcmShadow()
        .padding(.horizontal, 24)
    }

    // MARK: - Chat capsule

    /// Floating chat input on the cream background. Walnut fill + brass
    /// border give it the "cabinetry" warmth the old full-width walnut
    /// strip carried, but now contained to the capsule itself so the
    /// background runs unbroken through the home screen.
    private var chatCapsule: some View {
        Button {
            chatPresented = true
        } label: {
            HStack(spacing: 12) {
                Text("ask about your home…")
                    .font(CaptainTheme.body(15))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Image(systemName: "camera.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(CaptainTheme.brassBright)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(CaptainTheme.walnut)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                CaptainTheme.brass.opacity(0.6),
                                lineWidth: 1
                            )
                    )
            )
            .mcmShadow(intensity: 0.8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HomeView(session: .preview)
        .environmentObject(AppState())
}

private extension FirstSessionResponse {
    static let preview = FirstSessionResponse(
        jobId: "preview",
        address: "4221 Silsby Rd, University Heights, OH 44118",
        currentSeason: "summer",
        currentRenderingUrl: "/rendered/preview/summer.png",
        renderings: [:],
        palette: ["#b22222", "#ffffff", "#a9a9a9", "#d2b48c", "#000000", "#ffd700"],
        features: [],
        sourceUrls: [],
        fixture: true
    )
}
