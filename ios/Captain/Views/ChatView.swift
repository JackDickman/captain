import PhotosUI
import SwiftUI

/// The expanding chat surface (PRD §7.6). Presented from HomeView's chat bar.
/// Input accepts text + zero-or-more attached photos. Bubbles render any
/// attached images as a horizontal strip above the text.
/// Identifies a radar item the chat was opened from — used as a
/// kickoff signal so Captain auto-sends a what/why/when/how primer as
/// the first assistant message.
struct RadarKickoff: Equatable, Hashable {
    /// "calendar" for future / recurring entries, "suggestion" for the
    /// LLM-generated radar suggestions.
    let itemType: String
    /// Free-form prose Captain's chat model receives as the topic.
    /// For calendar items, this is just the entry's text. For
    /// suggestions, we include title + reason + timeframe so the
    /// model can riff on the original justification.
    let itemText: String
}

struct ChatView: View {
    let session: FirstSessionResponse
    /// When set, Captain sends an automatic primer message as soon as
    /// the chat opens — what the radar item is, why it matters, and
    /// how to act on it. The user's input stays empty so they can
    /// follow up naturally. PRD §7.6: "When chat is opened from a
    /// specific context… the input is context-aware."
    var radarKickoff: RadarKickoff? = nil
    /// When set, ChatView opens pinned to that specific past
    /// conversation (set by the history sheet). When nil, the chat
    /// surface loads the active conversation (the default-open case).
    var initialConversationId: Int? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""
    @State private var isSending = false
    @State private var loadError: String?
    /// The conversation this surface is currently pinned to. Set on
    /// load (either from `initialConversationId` or the active rule)
    /// and on every successful send so the backend's
    /// active-conversation rollover stays in sync with what iOS shows.
    @State private var conversationId: Int?
    /// Drives the history sheet presentation.
    @State private var showHistory = false
    /// What Captain is doing right now during an in-flight send. Drives
    /// the "thinking" bubble's content — animated dots for thinking /
    /// writing, a globe + query badge while a web search is in flight.
    @State private var sendStage: CaptainAPI.ChatStage = .thinking
    @FocusState private var inputFocused: Bool

    // Photo attachment state for the next message (up to MAX_PHOTOS).
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoData: [Data] = []
    /// Whether the system photo picker is currently presented. Bound
    /// from the photo-source Menu's "Photo Library" item.
    @State private var showingLibrary = false
    /// Whether the camera capture sheet is presented. Bound from the
    /// photo-source Menu's "Take Photo" item.
    @State private var showingCamera = false
    private let maxPhotos = 5

    var body: some View {
        ZStack {
            CaptainTheme.cream.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                messageList
                inputBar
            }
        }
        .task { await loadMessages() }
        .task {
            // If we opened from a radar item, kick off the auto-primer
            // as soon as the view appears. The kickoff handler shows
            // the thinking bubble immediately, runs the API call, then
            // refreshes history so Captain's first message lands.
            if let kickoff = radarKickoff {
                await runRadarKickoff(kickoff)
            }
        }
    }

    /// Fires the radar-kickoff API call and folds Captain's primer
    /// into the chat history. Behaves like a normal "send" turn from
    /// the user's perspective — thinking dots while Captain composes,
    /// then the message appears at the bottom — except no user bubble
    /// is shown because the user didn't type anything.
    private func runRadarKickoff(_ kickoff: RadarKickoff) async {
        isSending = true
        sendStage = .thinking
        defer { isSending = false }
        do {
            let resp = try await CaptainAPI.explainRadarItem(
                itemType: kickoff.itemType,
                itemText: kickoff.itemText,
                conversationId: conversationId,
            )
            if let landed = resp.conversationId {
                conversationId = landed
            }
            let payload = try await CaptainAPI.fetchMessages(
                conversationId: conversationId,
            )
            messages = payload.messages
            conversationId = payload.conversationId
        } catch {
            loadError = "Couldn't load context: \(error.localizedDescription)"
        }
    }

    // MARK: - Header (the home, receded)

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(CaptainTheme.creamDeep))
            }

            AsyncImage(
                url: CaptainAPI.renderingURL(for: session.currentRenderingUrl)
            ) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle().fill(CaptainTheme.creamDeep)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(CaptainTheme.brass, lineWidth: 1.5)
            )

            // Address is intentionally absent here — it lives only on
            // the home screen. The Captain title + the home thumbnail
            // next to it carry the "this home" context.
            Text("Captain")
                .font(CaptainTheme.display(17))
                .foregroundStyle(CaptainTheme.textPrimary)

            Spacer()

            // Browse past conversations + start a fresh thread. Quiet
            // affordance — small clock glyph in brass to distinguish
            // it from the overflow menu (a real destination, not an
            // overflow). Tap target matches the avatar/icon size used
            // on the home screen for visual consistency.
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CaptainTheme.brass)
                    .frame(width: 32, height: 32)
            }

            // Overflow menu for chat-level actions. Quiet by default —
            // the ellipsis is the only visible affordance.
            Menu {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Clear chat history", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CaptainTheme.cream)
        .confirmationDialog(
            "Clear chat history?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes every past conversation for this home. Your home profile, owner profile, and calendar aren't affected.")
        }
        .sheet(isPresented: $showHistory) {
            ConversationHistoryView(
                currentConversationId: conversationId,
                onPick: { picked in
                    conversationId = picked
                    showHistory = false
                    Task { await loadMessages() }
                }
            )
        }
    }

    @State private var showClearConfirm = false

    private func clearHistory() async {
        do {
            try await CaptainAPI.clearMessages()
            messages = []
            // Backend just deleted every conversation row — drop the
            // pinned id so the next send creates a fresh active thread.
            conversationId = nil
        } catch {
            loadError = "clear failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if messages.isEmpty && loadError == nil {
                        emptyState
                            .padding(.top, 32)
                            .padding(.horizontal, 24)
                    }
                    ForEach(messages) { msg in
                        bubble(for: msg)
                            .id(msg.id)
                    }
                    if isSending {
                        thinkingBubble
                            .id("thinking")
                    }
                    if let loadError {
                        Text(loadError)
                            .font(CaptainTheme.body(12))
                            .foregroundStyle(CaptainTheme.rust)
                            .padding(.horizontal, 24)
                    }
                }
                .padding(.vertical, 18)
            }
            // Same cushion as every other scrolling surface in Captain
            // — message bubbles fade softly under the chat header above
            // and into the input bar below instead of clipping hard.
            .captainScrollEdgeFade()
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation {
                    // Anchor differs by role:
                    //  - User's own message: pin to the BOTTOM so the
                    //    bubble they just sent sits right above the
                    //    input bar (familiar chat behavior).
                    //  - Assistant's message: pin to the TOP so a long
                    //    answer starts at the start, not buried at the
                    //    bottom with the user having to scroll up to
                    //    read the opening.
                    if last.role == .assistant {
                        proxy.scrollTo(last.id, anchor: .top)
                    } else {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: isSending) { _, sending in
                if sending {
                    withAnimation {
                        proxy.scrollTo("thinking", anchor: .bottom)
                    }
                }
            }
            .onChange(of: sendStage) { _, _ in
                // The thinking bubble grows when the model invokes a
                // web search (from animated dots to a 2-line globe +
                // query badge). Re-scroll on every stage change so the
                // bubble's new bottom stays visible above the input bar.
                guard isSending else { return }
                withAnimation {
                    proxy.scrollTo("thinking", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("ask Captain about your home")
                .font(CaptainTheme.display(18))
                .foregroundStyle(CaptainTheme.textPrimary)
            Text("Type a question, attach photos, or both. Captain remembers what you share.")
                .font(CaptainTheme.body(13))
                .foregroundStyle(CaptainTheme.textMuted)
                .multilineTextAlignment(.center)
        }
    }

    private func bubble(for msg: ChatMessage) -> some View {
        let isUser = msg.role == .user
        return HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                // The bubble proper — text + photo attachments.
                VStack(alignment: .leading, spacing: 8) {
                    if let urls = msg.imageUrls, !urls.isEmpty {
                        bubbleImages(urls: urls)
                    }
                    if !msg.content.isEmpty {
                        Text(attributedMarkdown(msg.content))
                            .font(CaptainTheme.body(15))
                            .foregroundStyle(isUser
                                ? .white
                                : CaptainTheme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground(for: msg.role))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(bubbleBorder(for: msg.role))

                // Persisted "searched the web" badge — durable counterpart
                // to the live in-flight indicator. Renders only on assistant
                // turns where the model actually invoked web_search.
                if !isUser,
                   let queries = msg.searches, !queries.isEmpty {
                    searchedBadge(queries: queries)
                }

                // Product cards attached to assistant messages (only
                // when the model used find_products with num_options >= 2).
                if !isUser,
                   let picks = msg.productPicks, !picks.isEmpty {
                    productCardsView(picks: picks)
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 16)
    }

    /// Compact "searched the web for X" footer rendered below an
    /// assistant message that ran one or more web searches. Quieter
    /// than the in-flight indicator — meant to read as a footnote, not
    /// a banner. Multiple queries collapse onto a single line joined
    /// with bullets.
    private func searchedBadge(queries: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CaptainTheme.brass.opacity(0.7))
            Text("searched the web · \(queries.joined(separator: " · "))")
                .font(CaptainTheme.body(11))
                .foregroundStyle(CaptainTheme.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 6)
    }

    /// Vertical stack of product picks Captain attached to an assistant
    /// turn, plus a small affiliate-disclosure footer below them.
    private func productCardsView(picks: [ProductPick]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(picks.indices, id: \.self) { i in
                productCard(picks[i])
            }
            // FTC requires this — quiet but present. Spec'd to match
            // the muted secondary type elsewhere in the app.
            Text("Captain earns from qualifying purchases.")
                .font(CaptainTheme.body(10))
                .foregroundStyle(CaptainTheme.textMuted.opacity(0.7))
                .padding(.top, 2)
                .padding(.leading, 4)
        }
    }

    /// One compact product card. Tapping anywhere opens the affiliate
    /// URL in the user's browser (Safari / Amazon app via universal
    /// link). Same visual register as the weather + radar cards:
    /// creamDeep fill, brass border, MCM warmth.
    private func productCard(_ pick: ProductPick) -> some View {
        Link(destination: URL(string: pick.url)
             ?? URL(string: "https://amazon.com")!) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(CaptainTheme.brass)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pick.retailer.lowercased())
                        .font(CaptainTheme.label(9))
                        .foregroundStyle(CaptainTheme.brass)
                        .tracking(1.0)
                        .textCase(.uppercase)
                    Text(pick.title)
                        .font(CaptainTheme.body(14, weight: .medium))
                        .foregroundStyle(CaptainTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !pick.blurb.isEmpty {
                        Text(pick.blurb)
                            .font(CaptainTheme.body(12))
                            .foregroundStyle(CaptainTheme.textMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 14))
                    .foregroundStyle(CaptainTheme.brass.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(CaptainTheme.creamDeep.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                CaptainTheme.brass.opacity(0.35),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// One large image when there's just one; otherwise a horizontal strip
    /// of square thumbnails (140pt) inside a scroll view so the bubble
    /// stays a sensible width while showing all attachments.
    @ViewBuilder
    private func bubbleImages(urls: [String]) -> some View {
        if urls.count == 1 {
            bubbleImage(url: urls[0], side: 220)
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(urls, id: \.self) { url in
                        bubbleImage(url: url, side: 140)
                            .frame(width: 140, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: 280)
        }
    }

    @ViewBuilder
    private func bubbleImage(url: String, side: CGFloat) -> some View {
        AsyncImage(url: CaptainAPI.renderingURL(for: url)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                Rectangle().fill(.black.opacity(0.1))
                    .overlay(ProgressView().tint(.white))
            case .failure:
                Rectangle().fill(.black.opacity(0.1))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.6))
                    )
            @unknown default:
                EmptyView()
            }
        }
    }

    private func attributedMarkdown(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: content, options: options))
            ?? AttributedString(content)
    }

    private func bubbleBackground(for role: ChatMessage.Role) -> Color {
        switch role {
        case .user: return CaptainTheme.walnut
        case .assistant: return CaptainTheme.creamDeep
        }
    }

    @ViewBuilder
    private func bubbleBorder(for role: ChatMessage.Role) -> some View {
        if role == .assistant {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(CaptainTheme.brass.opacity(0.45), lineWidth: 1)
        }
    }

    private var thinkingBubble: some View {
        HStack {
            thinkingContent
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(CaptainTheme.creamDeep)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.45),
                            lineWidth: 1
                        )
                )
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 16)
    }

    /// Content of the in-flight assistant bubble. Animated dots for the
    /// default "thinking" / "writing" phases; a globe + query badge
    /// while Captain is running a web search so the user can see what's
    /// being looked up live.
    @ViewBuilder
    private var thinkingContent: some View {
        switch sendStage {
        case .searching(let query):
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CaptainTheme.brass)
                VStack(alignment: .leading, spacing: 1) {
                    Text("searching the web")
                        .font(CaptainTheme.label(10))
                        .foregroundStyle(CaptainTheme.textMuted)
                        .tracking(0.8)
                        .textCase(.uppercase)
                    if !query.isEmpty {
                        Text(query)
                            .font(CaptainTheme.body(13, weight: .medium))
                            .foregroundStyle(CaptainTheme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .writing, .thinking:
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(CaptainTheme.textMuted)
                        .frame(width: 7, height: 7)
                        .opacity(0.4)
                        .scaleEffect(thinkingScale(at: i))
                }
            }
        }
    }

    @State private var thinkingPhase: Double = 0
    private let thinkingTimer = Timer.publish(
        every: 0.4, on: .main, in: .common
    ).autoconnect()

    private func thinkingScale(at index: Int) -> CGFloat {
        let beat = (Int(thinkingPhase) + index) % 3
        return beat == 0 ? 1.3 : 1.0
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().background(CaptainTheme.walnut.opacity(0.15))

            if !photoData.isEmpty {
                pendingPhotosRow
            }

            HStack(alignment: .bottom, spacing: 10) {
                photoButton

                TextField(
                    "",
                    text: $draft,
                    prompt: Text(inputPrompt)
                        .foregroundStyle(CaptainTheme.textMuted),
                    axis: .vertical
                )
                .font(CaptainTheme.body(15))
                .foregroundStyle(CaptainTheme.textPrimary)
                .focused($inputFocused)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(CaptainTheme.creamDeep)
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(
                                canSend ? CaptainTheme.walnut
                                        : CaptainTheme.walnut.opacity(0.3)
                            )
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    CaptainTheme.brass,
                                    lineWidth: canSend ? 1 : 0
                                )
                        )
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(CaptainTheme.cream)
        }
        .onReceive(thinkingTimer) { _ in
            if isSending { thinkingPhase += 1 }
        }
    }

    private var inputPrompt: String {
        photoData.isEmpty ? "ask about your home…" : "add a note (optional)…"
    }

    /// Photo source menu — tap the brass camera button to choose between
    /// the system photo library (multi-select) and the in-app camera
    /// (one shot per tap, repeat to add more). Picks accumulate into
    /// `photoData` up to `maxPhotos`. Both items disable when the
    /// pending strip is already full.
    private var photoButton: some View {
        let slotsLeft = max(0, maxPhotos - photoData.count)
        let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
        return Menu {
            Button {
                showingLibrary = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            .disabled(slotsLeft == 0)

            Button {
                showingCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera.fill")
            }
            .disabled(slotsLeft == 0 || !cameraAvailable)
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 15))
                .foregroundStyle(CaptainTheme.brass)
                .frame(width: 36, height: 36)
                .background(Circle().fill(CaptainTheme.creamDeep))
                .overlay(
                    Circle()
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.4),
                            lineWidth: 1
                        )
                )
        }
        .photosPicker(
            isPresented: $showingLibrary,
            selection: $photoItems,
            maxSelectionCount: max(1, slotsLeft),
            selectionBehavior: .ordered,
            matching: .images
        )
        .onChange(of: photoItems) { _, newItems in
            // Library selections are appended to (not replacing) the
            // pending strip, so users can mix library + camera picks
            // within a single message.
            Task { @MainActor in
                guard !newItems.isEmpty else { return }
                var loaded: [Data] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(
                        type: Data.self,
                    ) {
                        loaded.append(data)
                    }
                }
                let combined = photoData + loaded
                photoData = Array(combined.prefix(maxPhotos))
                // Clear the picker's selection state so the next open
                // starts fresh (otherwise the previously-picked items
                // would re-load on every subsequent invocation).
                photoItems = []
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { data in
                guard photoData.count < maxPhotos else { return }
                photoData.append(data)
            }
            .ignoresSafeArea()
        }
    }

    /// Horizontal strip of pending-photo thumbnails, each removable. Sits
    /// above the input row when one or more photos are staged.
    private var pendingPhotosRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(photoData.enumerated()), id: \.offset) { idx, data in
                    if let img = UIImage(data: data) {
                        pendingChip(image: img, index: idx)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func pendingChip(image: UIImage, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(CaptainTheme.brass.opacity(0.5), lineWidth: 1)
                )
            Button {
                removePhoto(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(CaptainTheme.walnut))
            }
            .offset(x: 5, y: -5)
        }
    }

    private func removePhoto(at index: Int) {
        guard index < photoData.count else { return }
        photoData.remove(at: index)
        if index < photoItems.count {
            photoItems.remove(at: index)
        }
    }

    private var canSend: Bool {
        guard !isSending else { return false }
        let hasText = !draft
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !photoData.isEmpty
    }

    // MARK: - Network

    private func loadMessages() async {
        do {
            let payload = try await CaptainAPI.fetchMessages(
                conversationId: conversationId ?? initialConversationId,
            )
            messages = payload.messages
            conversationId = payload.conversationId
        } catch {
            loadError = "couldn't load history: \(error.localizedDescription)"
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let toSend = photoData
        guard (!text.isEmpty || !toSend.isEmpty), !isSending else { return }
        draft = ""
        photoData = []
        photoItems = []
        isSending = true
        sendStage = .thinking

        // Optimistic insert — show photos via data: URLs so the bubble
        // appears instantly while the upload runs in the background.
        let optimisticUrls: [String] = toSend.map { data in
            "data:image/jpeg;base64,\(data.base64EncodedString())"
        }
        let optimistic = ChatMessage(
            id: -Int.random(in: 1...1_000_000),
            role: .user,
            content: text,
            imageUrls: optimisticUrls.isEmpty ? nil : optimisticUrls,
            productPicks: nil,
            searches: nil,
            createdAt: Date().timeIntervalSince1970
        )
        messages.append(optimistic)
        do {
            let resp = try await CaptainAPI.sendChatMessage(
                text,
                photos: toSend,
                conversationId: conversationId,
                onStage: { stage in
                    sendStage = stage
                }
            )
            // Backend may have rolled the conversation (active-window
            // expired between opens). Pin to whatever it routed to so
            // the next send stays in the right thread.
            if let landed = resp.conversationId {
                conversationId = landed
            }
            let payload = try await CaptainAPI.fetchMessages(
                conversationId: conversationId,
            )
            messages = payload.messages
            conversationId = payload.conversationId
        } catch {
            messages.removeAll { $0.id == optimistic.id }
            loadError = "send failed: \(error.localizedDescription)"
        }
        isSending = false
    }
}

#Preview {
    ChatView(session: .previewForChat)
}

private extension FirstSessionResponse {
    static let previewForChat = FirstSessionResponse(
        jobId: "preview",
        address: "4221 Silsby Rd, University Heights, OH 44118",
        currentSeason: "spring",
        currentRenderingUrl: "/rendered/fixture-silsby/spring.png",
        renderings: [:],
        palette: ["#b22222", "#ffffff", "#a9a9a9",
                  "#d2b48c", "#000000", "#ffd700"],
        features: [],
        sourceUrls: [],
        fixture: true
    )
}
