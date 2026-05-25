import PhotosUI
import SwiftUI

/// The expanding chat surface (PRD §7.6). Presented from HomeView's chat bar.
/// Input accepts text + zero-or-more attached photos. Bubbles render any
/// attached images as a horizontal strip above the text.
struct ChatView: View {
    let session: FirstSessionResponse
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""
    @State private var isSending = false
    @State private var loadError: String?
    @FocusState private var inputFocused: Bool

    // Photo attachment state for the next message (up to MAX_PHOTOS).
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoData: [Data] = []
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

            VStack(alignment: .leading, spacing: 2) {
                Text("Captain")
                    .font(CaptainTheme.display(15))
                    .foregroundStyle(CaptainTheme.textPrimary)
                Text(session.address)
                    .font(CaptainTheme.body(11))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CaptainTheme.cream)
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
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: isSending) { _, sending in
                if sending {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
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
        HStack(alignment: .top) {
            if msg.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                if let urls = msg.imageUrls, !urls.isEmpty {
                    bubbleImages(urls: urls)
                }
                if !msg.content.isEmpty {
                    Text(attributedMarkdown(msg.content))
                        .font(CaptainTheme.body(15))
                        .foregroundStyle(msg.role == .user
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
            if msg.role == .assistant { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 16)
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
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(CaptainTheme.textMuted)
                        .frame(width: 7, height: 7)
                        .opacity(0.4)
                        .scaleEffect(thinkingScale(at: i))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(CaptainTheme.creamDeep)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(CaptainTheme.brass.opacity(0.45), lineWidth: 1)
            )
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 16)
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

    private var photoButton: some View {
        PhotosPicker(
            selection: $photoItems,
            maxSelectionCount: maxPhotos,
            selectionBehavior: .ordered,
            matching: .images
        ) {
            Image(systemName: "camera.fill")
                .font(.system(size: 15))
                .foregroundStyle(CaptainTheme.brass)
                .frame(width: 36, height: 36)
                .background(Circle().fill(CaptainTheme.creamDeep))
                .overlay(
                    Circle()
                        .strokeBorder(CaptainTheme.brass.opacity(0.4), lineWidth: 1)
                )
        }
        .onChange(of: photoItems) { _, newItems in
            Task { @MainActor in
                var loaded: [Data] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        loaded.append(data)
                    }
                }
                photoData = loaded
            }
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
            messages = try await CaptainAPI.fetchMessages()
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
            createdAt: Date().timeIntervalSince1970
        )
        messages.append(optimistic)
        do {
            _ = try await CaptainAPI.sendChatMessage(text, photos: toSend)
            let fresh = try await CaptainAPI.fetchMessages()
            messages = fresh
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
