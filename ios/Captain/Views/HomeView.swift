import SwiftUI

/// Post-first-session home screen. The rendered home is the dominant visual
/// (PRD §7.4), framed in brass like a piece of cherished art on a wall. Chat
/// bar sits below on a wood-grain "cabinetry" surface. Bottom-sheet radar
/// arrives in a later milestone.
struct HomeView: View {
    let session: FirstSessionResponse
    @EnvironmentObject var appState: AppState
    @State private var chatPresented = false
    @State private var weatherPeriods: [WeatherPeriod] = []

    private var accent: Color {
        Color(hex: session.palette.first ?? "#7a6750")
    }
    private var accent2: Color {
        Color(hex: session.palette.dropFirst().first ?? "#d8b486")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            background
            content
            chatBar
        }
        .fullScreenCover(isPresented: $chatPresented) {
            ChatView(session: session)
        }
        .task { await loadWeather() }
        .onAppear {
            // Debug: launch with --auto-chat to open ChatView immediately
            // (used for screenshots and validating chat round-trip without
            // having to drive the chat-bar tap manually).
            if ProcessInfo.processInfo.arguments.contains("--auto-chat") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    chatPresented = true
                }
            }
        }
    }

    private func loadWeather() async {
        if let periods = try? await CaptainAPI.fetchWeather() {
            weatherPeriods = periods
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
            greetingBlock
            Spacer().frame(height: 22)
            heroImage
            Spacer().frame(height: 18)
            WeatherWidget(periods: weatherPeriods)
                .padding(.horizontal, 24)
            Spacer()
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

    private var greetingBlock: some View {
        HStack(alignment: .bottom, spacing: 12) {
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
        }
        .padding(.horizontal, 26)
        .padding(.top, 28)
        // Debug: long-press to reset the first session and start over.
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

    // MARK: - Chat bar (walnut surface)

    private var chatBar: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                CaptainTheme.walnut
                VStack(spacing: 12) {
                    Capsule()
                        .fill(CaptainTheme.brass.opacity(0.8))
                        .frame(width: 38, height: 4)
                        .padding(.top, 12)
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
                                .fill(.white.opacity(0.08))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            CaptainTheme.brass.opacity(0.45),
                                            lineWidth: 1
                                        )
                                )
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 26)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 130)
        }
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
