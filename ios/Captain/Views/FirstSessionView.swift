import PhotosUI
import SwiftUI

/// The very first thing a new user sees: take/pick a photo of their home,
/// type the address, submit. On success, AppState transitions to HomeView.
struct FirstSessionView: View {
    @EnvironmentObject var appState: AppState

    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var address: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadingMessage: String = "Captain is getting to know your home"
    /// Speculative-prerender id from /prerender. Set in the background as
    /// soon as the user picks a photo; passed to /first-session on submit
    /// so the backend can skip re-uploading and re-rendering.
    @State private var prefetchId: String?
    @State private var prefetchTask: Task<Void, Never>?

    private var canSubmit: Bool {
        photoData != nil
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
    }

    var body: some View {
        ZStack {
            CaptainTheme.cream.ignoresSafeArea()

            if isLoading {
                loadingView
            } else {
                formView
            }
        }
        .animation(.easeInOut(duration: 0.4), value: isLoading)
        .onAppear {
            // Debug: pin the loading screen indefinitely (for screenshots).
            if ProcessInfo.processInfo.arguments.contains("--show-loading") {
                isLoading = true
                return
            }
            maybeAutoSubmit()
        }
    }

    /// Debug: when launched with `--auto-submit`, immediately load the
    /// bundled test photo + canned Silsby address and fire the real
    /// first-session pipeline. Used to validate the iOS↔backend contract
    /// end-to-end without manually driving the photo picker.
    private func maybeAutoSubmit() {
        guard ProcessInfo.processInfo.arguments.contains("--auto-submit") else { return }
        guard let url = Bundle.main.url(forResource: "TestHome", withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else {
            errorMessage = "Auto-submit: TestHome.jpg not found in bundle"
            return
        }
        photoData = data
        address = "4221 Silsby Rd, University Heights, OH 44118"
        // Small delay so the form briefly flashes before loading state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            submit()
        }
    }

    // MARK: - Form

    private var formView: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                photoPickerView
                addressField
                if let errorMessage {
                    Text(errorMessage)
                        .font(CaptainTheme.body(13))
                        .foregroundStyle(CaptainTheme.rust)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                submitButton
            }
            .padding(.top, 56)
            .padding(.bottom, 32)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Captain")
                .font(CaptainTheme.display(42))
                .foregroundStyle(CaptainTheme.textPrimary)
            Text("let's get to know your home")
                .font(CaptainTheme.body(14))
                .foregroundStyle(CaptainTheme.textMuted)
        }
    }

    private var photoPickerView: some View {
        // Square picker that scales with the screen: caps at 300pt on
        // larger phones so it doesn't feel oversized, but shrinks to
        // fit on smaller ones via the outer horizontal padding. The
        // ZStack lets the same frame host either the placeholder or
        // the loaded photo without repeating the geometry.
        PhotosPicker(selection: $photoItem, matching: .images) {
            ZStack {
                if let photoData, let img = UIImage(data: photoData) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    CaptainTheme.creamDeep
                    placeholderInner
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 300)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        photoData != nil
                            ? CaptainTheme.brass
                            : CaptainTheme.walnut.opacity(0.35),
                        style: StrokeStyle(
                            lineWidth: photoData != nil ? 3 : 1.5,
                            dash: photoData != nil ? [] : [6, 4]
                        )
                    )
            )
            .mcmShadow(intensity: photoData != nil ? 1.0 : 0.5)
            .padding(.horizontal, 32)
        }
        .onChange(of: photoItem) { _, newValue in
            Task { @MainActor in
                if let data = try? await newValue?.loadTransferable(type: Data.self) {
                    photoData = data
                    // Kick off speculative prerender so the slowest stage
                    // is already running by the time the user types their
                    // address and submits. Cancel any in-flight prefetch
                    // from a previously-selected photo first.
                    prefetchTask?.cancel()
                    prefetchId = nil
                    prefetchTask = Task { await runPrefetch(data) }
                }
            }
        }
    }

    /// Background prerender call. Silent on failure — submit will fall
    /// back to the regular photo-upload + fresh-render path if this
    /// didn't land. Sets `prefetchId` on success so submit() can pass
    /// it through.
    private func runPrefetch(_ data: Data) async {
        do {
            let id = try await CaptainAPI.prerender(photo: data)
            if Task.isCancelled { return }
            await MainActor.run { self.prefetchId = id }
            if id != nil {
                print("[prefetch] started \(id ?? "")")
            }
        } catch {
            print("[prefetch] failed (will fall back on submit): \(error)")
        }
    }

    private var placeholderInner: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.fill")
                .font(.system(size: 28))
                .foregroundStyle(CaptainTheme.brass)
            Text("photo of your home")
                .font(CaptainTheme.body(14))
                .foregroundStyle(CaptainTheme.textMuted)
        }
    }

    private var addressField: some View {
        TextField(
            "",
            text: $address,
            prompt: Text("your home's address")
                .foregroundStyle(CaptainTheme.textMuted),
            axis: .vertical
        )
        .font(CaptainTheme.body(16))
        .foregroundStyle(CaptainTheme.textPrimary)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled(true)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(CaptainTheme.creamDeep)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(CaptainTheme.walnut.opacity(0.18), lineWidth: 1)
        )
        .padding(.horizontal, 32)
        .frame(minHeight: 50)
    }

    private var submitButton: some View {
        // Pre-first-session, the app's identity is intentionally muted —
        // walnut + brass only. The home's palette unlocks the stained-glass
        // aesthetic after submission.
        Button(action: submit) {
            ZStack {
                (canSubmit ? CaptainTheme.walnut : CaptainTheme.walnut.opacity(0.3))
                Text("introduce yourself")
                    .font(CaptainTheme.display(18))
                    .foregroundStyle(.white)
                    .padding(.vertical, 16)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(CaptainTheme.brass, lineWidth: canSubmit ? 1.5 : 0)
            )
            .mcmShadow(intensity: canSubmit ? 1.0 : 0.3)
        }
        .disabled(!canSubmit)
        .padding(.horizontal, 32)
    }

    // MARK: - Loading

    /// Full-bleed stained-glass mosaic with a soft cream card narrating
    /// what Captain is doing right now. The message text is bound to the
    /// backend's stage updates (via the progress callback in
    /// CaptainAPI.firstSession), so it animates through stages:
    /// "Looking up your home…" → "Studying the photo…" → "Painting a
    /// portrait of your home…" → "Almost there…".
    private var loadingView: some View {
        ZStack {
            StainedGlassPanel(rows: 14, cols: 6)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Text(loadingMessage)
                    .font(CaptainTheme.display(22))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .id(loadingMessage)  // forces transition on text change
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                Text("this can take a minute…")
                    .font(CaptainTheme.body(13))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(CaptainTheme.cream.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                CaptainTheme.brass.opacity(0.5),
                                lineWidth: 1
                            )
                    )
            )
            .mcmShadow()
            .padding(.horizontal, 36)
        }
        .animation(.easeInOut(duration: 0.45), value: loadingMessage)
    }

    // MARK: - Submit

    private func submit() {
        guard let photoData else { return }
        errorMessage = nil
        isLoading = true
        loadingMessage = "Captain is getting to know your home"

        Task {
            do {
                let response = try await CaptainAPI.firstSession(
                    photo: photoData,
                    photoFilename: "photo.jpg",
                    address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                    prefetchId: prefetchId,
                    progress: { message in
                        loadingMessage = message
                    }
                )
                appState.setFirstSession(response)
            } catch CaptainAPI.APIError.userMessage(let msg) {
                // Validation-style error from the backend — surface verbatim,
                // no "backend on localhost…" hint (the backend was clearly
                // reachable; it just rejected the input).
                errorMessage = msg
            } catch {
                errorMessage = error.localizedDescription
                    + "\n\nMake sure the backend is running on localhost:8000."
            }
            isLoading = false
        }
    }
}

#Preview {
    FirstSessionView()
        .environmentObject(AppState())
}
