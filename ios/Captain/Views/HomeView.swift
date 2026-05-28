import SwiftUI

/// Post-first-session home screen. The rendered home is the dominant visual
/// (PRD §7.4), framed in brass like a piece of cherished art on a wall. Chat
/// bar sits below on a wood-grain "cabinetry" surface. Bottom-sheet radar
/// arrives in a later milestone.
struct HomeView: View {
    let session: FirstSessionResponse
    @EnvironmentObject var appState: AppState
    /// Single source of truth for "is the chat surface open and what
    /// draft does it open with?" — using `.fullScreenCover(item:)`
    /// guarantees that each set creates a fresh identity, so SwiftUI
    /// fully re-mounts ChatView with the new draft (rather than reusing
    /// an existing instance whose @State is already initialized).
    @State private var chatPresentation: ChatPresentation?
    @State private var profilePresented = false
    @State private var radarPresented = false
    @State private var huntPresented = false
    @State private var weatherPeriods: [WeatherPeriod] = []
    @State private var radar: RadarResponse?
    @State private var radarLoading = true
    @State private var hunt: HuntResponse?
    /// Captain's optional "on this day" recall line. nil on most days for
    /// a young home; surfaces only when the calendar has an anniversary.
    @State private var biographer: BiographerRecall?
    /// Set by RadarView's tap callback right before it dismisses; the
    /// sheet's onDismiss reads this to decide whether to open chat.
    @State private var pendingRadarKickoff: RadarKickoff?

    /// Identifiable wrapper so `.fullScreenCover(item:)` treats every
    /// new chat presentation as a unique view identity. The UUID is
    /// the key — without it, SwiftUI happily reuses the previous
    /// ChatView instance and the kickoff never lands.
    fileprivate struct ChatPresentation: Identifiable {
        let id = UUID()
        let radarKickoff: RadarKickoff?
    }


    var body: some View {
        ZStack {
            background
            content
        }
        .fullScreenCover(item: $chatPresentation) { presentation in
            ChatView(
                session: session,
                radarKickoff: presentation.radarKickoff,
            )
        }
        .sheet(isPresented: $profilePresented) {
            ProfileView(session: session)
        }
        .sheet(isPresented: $radarPresented, onDismiss: {
            // If the user tapped a radar item, the closure stored a
            // kickoff. Now that the radar sheet is gone, open chat
            // with that kickoff — async dispatch so the sheet-dismiss
            // animation finishes before the cover-present animation
            // starts (sheet→cover transitions are otherwise twitchy).
            if let kickoff = pendingRadarKickoff {
                pendingRadarKickoff = nil
                DispatchQueue.main.async {
                    chatPresentation = ChatPresentation(
                        radarKickoff: kickoff,
                    )
                }
            }
        }) {
            if let radar {
                RadarView(radar: radar) { kickoff in
                    pendingRadarKickoff = kickoff
                }
            }
        }
        .sheet(isPresented: $huntPresented, onDismiss: {
            Task { await loadHunt() }
        }) {
            HuntView()
        }
        .task { await loadWeather() }
        .task { await loadRadar() }
        .task { await loadHunt() }
        .task { await loadBiographer() }
        .task {
            // PRD §13 success criterion: weekly opens. Logged once per
            // appearance; the backend de-noises in aggregation.
            await CaptainAPI.logEvent("home_screen_view")
        }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            // Debug: launch with --auto-chat / --show-profile to open the
            // corresponding sheet immediately (used for screenshots).
            if args.contains("--auto-chat") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    chatPresentation = ChatPresentation(radarKickoff: nil)
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

    private func loadHunt() async {
        if let result = try? await CaptainAPI.fetchHunt() {
            hunt = result
        }
    }

    private func loadBiographer() async {
        biographer = await CaptainAPI.fetchBiographer()
    }

    // MARK: - Background

    private var background: some View {
        CaptainTheme.cream
            .ignoresSafeArea()
    }

    // MARK: - Content

    /// Three-part layout: pinned topBlock, scrolling middle (hero +
    /// widgets), pinned chat capsule. The middle is in a ScrollView so
    /// the hero portrait can stay its natural full-width-square size
    /// without competing for vertical room — on smaller phones (SE,
    /// 17e) the user scrolls a little; on larger phones (Pro Max)
    /// everything fits and the scroll surface barely engages.
    private var content: some View {
        VStack(spacing: 0) {
            topBlock
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 18)
                    heroImage
                    if let hunt, !hunt.complete {
                        Spacer().frame(height: 14)
                        huntBanner(hunt)
                            .padding(.horizontal, 24)
                    }
                    Spacer().frame(height: 14)
                    WeatherWidget(periods: weatherPeriods)
                        .padding(.horizontal, 24)
                    Spacer().frame(height: 10)
                    RadarStrip(radar: radar, isLoading: radarLoading) {
                        if radar != nil {
                            radarPresented = true
                            GestureHint.markDiscovered(.radarCard)
                            Task {
                                await CaptainAPI.logEvent(
                                    "radar_card_open"
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .gestureHint(.radarCard)
                    Spacer().frame(height: 12)
                }
            }
            // Biographer line — Captain speaking unbidden when the home
            // has a calendar anniversary today. Sits just above the chat
            // capsule so it reads as a quiet aside, not a header.
            if let biographer {
                biographerLine(biographer)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
            // Bottom chat capsule sits inline in the column now (no
            // walnut surface beneath it) — the cream background runs
            // unbroken from the home image all the way to the safe
            // area.
            chatCapsule
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }

    /// Quiet, decorative "on this day" line. Italics + muted tone so it
    /// reads as an aside, not an instruction. Single line, truncates
    /// rather than wraps — Captain shouldn't dominate the home screen.
    private func biographerLine(_ recall: BiographerRecall) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 11))
                .foregroundStyle(CaptainTheme.brass.opacity(0.7))
            Text(recall.text)
                .font(CaptainTheme.body(13))
                .italic()
                .foregroundStyle(CaptainTheme.textMuted)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 0)
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
                GestureHint.markDiscovered(.cornerAvatar)
                Task {
                    await CaptainAPI.logEvent("profile_drawer_open")
                }
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
            .gestureHint(.cornerAvatar)
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
        // maxWidth before aspectRatio so the square fills the row's
        // available width. layoutPriority(1) keeps the square from
        // shrinking when the column is vertically constrained on
        // smaller phones (iPhone SE etc.) — without it, .fit honors
        // the smaller of {width, height available} and the image
        // collapses to ~40% of screen width.
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .layoutPriority(1)
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

    // MARK: - Hunt banner

    /// Quiet entry point for the scavenger hunt — visible above the
    /// weather widget until the hunt is complete. Disappears entirely
    /// once every applicable item has been resolved (done / skipped /
    /// not-applicable).
    private func huntBanner(_ hunt: HuntResponse) -> some View {
        Button {
            huntPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "map.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(CaptainTheme.brass)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(huntBannerLead(hunt))
                        .font(CaptainTheme.body(14, weight: .medium))
                        .foregroundStyle(CaptainTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(huntBannerDetail(hunt))
                        .font(CaptainTheme.body(11))
                        .foregroundStyle(CaptainTheme.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CaptainTheme.brass)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(CaptainTheme.creamDeep.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                CaptainTheme.brass.opacity(0.4),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func huntBannerLead(_ hunt: HuntResponse) -> String {
        if hunt.resolved == 0 {
            return "Captain wants to learn your home"
        }
        return "Pick up where you left off"
    }

    private func huntBannerDetail(_ hunt: HuntResponse) -> String {
        if hunt.resolved == 0 {
            return "A quick guided tour — \(hunt.total) things"
        }
        return "\(hunt.resolved) of \(hunt.total) done"
    }

    // MARK: - Chat capsule

    /// Floating chat input on the cream background. Walnut fill + brass
    /// border give it the "cabinetry" warmth the old full-width walnut
    /// strip carried, but now contained to the capsule itself so the
    /// background runs unbroken through the home screen.
    private var chatCapsule: some View {
        Button {
            chatPresentation = ChatPresentation(radarKickoff: nil)
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
