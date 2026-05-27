import PhotosUI
import SwiftUI
import UIKit

/// One item in the scavenger hunt — opens as a sheet from HuntView.
/// Handles both photo items (require a captured image) and Q&A items
/// (require a written answer). The user can submit, skip for now, or
/// mark not-applicable; in all cases the parent gets the updated
/// HuntResponse via the `onUpdated` callback.
struct HuntItemView: View {
    let item: HuntItem
    let onUpdated: (HuntResponse) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var notes: String = ""
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingLibrary = false
    @State private var showingCamera = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let maxNoteLength = 600

    /// Either a captured photo (preferred — fresh state) or, when the
    /// item was previously completed, the persisted photo URL we'd
    /// re-render from the backend.
    private var hasPhotoForSubmit: Bool {
        photoData != nil
    }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        if item.hasPhoto {
            // Photo items require a photo this round (or a previous
            // photo if the user is editing).
            return photoData != nil
                || (item.status == "done" && item.photoUrl != nil)
        }
        // Text-only items require non-empty answer.
        return !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            CaptainTheme.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        intro
                        // Pre-fill provenance banner — when the notes
                        // field has come from somewhere other than the
                        // user (docs scan or profile match), tell them.
                        if let banner = prefillBanner { banner }
                        if item.hasPhoto { photoBlock }
                        questionBlock
                        if let errorMessage {
                            Text(errorMessage)
                                .font(CaptainTheme.body(12))
                                .foregroundStyle(CaptainTheme.rust)
                        }
                        actionButtons
                        secondaryActions
                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
            }
        }
        .onAppear {
            // Pre-fill from any previously captured notes so the user
            // can review / edit when revisiting a done item.
            notes = item.notes ?? ""
        }
        .photosPicker(
            isPresented: $showingLibrary,
            selection: $photoItem,
            matching: .images
        )
        .onChange(of: photoItem) { _, newValue in
            Task { @MainActor in
                if let data = try? await newValue?.loadTransferable(
                    type: Data.self,
                ) {
                    photoData = data
                }
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { data in
                photoData = data
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(CaptainTheme.creamDeep))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CaptainTheme.cream)
    }

    /// Returns a banner when this item came in with a pre-fill from
    /// somewhere — docs upload, or a match Captain found in home.md.
    /// Nil when there's nothing special to call out (fresh item, or
    /// already done by the user).
    @ViewBuilder
    private var prefillBanner: AnyView? {
        if item.notesSource == "documents" && item.status == "pending" {
            return AnyView(
                prefillCard(
                    icon: "doc.text.viewfinder",
                    title: "From your documents",
                    body:
                        "Captain pulled this from the docs you uploaded. "
                        + "Tweak if needed, then save to confirm."
                )
            )
        }
        if let hint = item.profileHint, item.status == "pending" {
            return AnyView(
                prefillCard(
                    icon: "sparkles",
                    title: "Captain seems to know this already",
                    body:
                        "From earlier conversations: \"\(hint)\"\nConfirm or update."
                )
            )
        }
        return nil
    }

    private func prefillCard(
        icon: String, title: String, body: String,
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CaptainTheme.brass)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(CaptainTheme.label(10))
                    .foregroundStyle(CaptainTheme.brass)
                    .tracking(1.0)
                    .textCase(.uppercase)
                Text(body)
                    .font(CaptainTheme.body(13))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CaptainTheme.brass.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.45),
                            lineWidth: 1
                        )
                )
        )
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.category.lowercased())
                .font(CaptainTheme.label(10))
                .foregroundStyle(CaptainTheme.brass)
                .tracking(1.2)
                .textCase(.uppercase)
            Text(item.title)
                .font(CaptainTheme.display(24))
                .foregroundStyle(CaptainTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.85)
            Text(item.description)
                .font(CaptainTheme.body(14))
                .foregroundStyle(CaptainTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var photoBlock: some View {
        if let where_ = item.whereToLook {
            hintCard(text: where_)
        }
        photoCaptureRow
    }

    private func hintCard(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "binoculars.fill")
                .font(.system(size: 14))
                .foregroundStyle(CaptainTheme.brass)
                .padding(.top, 2)
            Text(text)
                .font(CaptainTheme.body(13))
                .foregroundStyle(CaptainTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(CaptainTheme.creamDeep.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.3),
                            lineWidth: 1
                        )
                )
        )
    }

    /// Photo capture surface — shows either the freshly-picked image,
    /// the previously-uploaded image (when the item was already done),
    /// or two action buttons (Library / Camera).
    @ViewBuilder
    private var photoCaptureRow: some View {
        if let data = photoData, let img = UIImage(data: data) {
            photoPreview(uiImage: img, isFresh: true)
        } else if item.status == "done", let url = item.photoUrl {
            AsyncImage(
                url: CaptainAPI.renderingURL(for: url),
            ) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    Rectangle().fill(CaptainTheme.creamDeep)
                        .overlay(ProgressView().tint(CaptainTheme.brass))
                case .failure:
                    Rectangle().fill(CaptainTheme.creamDeep)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(CaptainTheme.brass.opacity(0.5))
                        )
                @unknown default:
                    EmptyView()
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        CaptainTheme.brass.opacity(0.45), lineWidth: 1,
                    )
            )
            replacePhotoButtons
        } else {
            photoSourceButtons
        }
    }

    private func photoPreview(uiImage: UIImage, isFresh: Bool) -> some View {
        VStack(spacing: 10) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.55), lineWidth: 1,
                        )
                )
            if isFresh {
                Button {
                    photoData = nil
                    photoItem = nil
                } label: {
                    Text("retake / choose another")
                        .font(CaptainTheme.body(12, weight: .medium))
                        .foregroundStyle(CaptainTheme.brass)
                }
            }
        }
    }

    private var replacePhotoButtons: some View {
        HStack(spacing: 10) {
            Text("Already on file — submit a new photo to replace it.")
                .font(CaptainTheme.body(12))
                .foregroundStyle(CaptainTheme.textMuted)
            Spacer()
        }
        .padding(.top, 4)
        .overlay(alignment: .bottom) {
            // Reuse the two-button source row below so the user can
            // pick fresh media at any time.
            EmptyView()
        }
        // Show the source buttons too so retake is one tap away.
        // Stacked below in the body via the surrounding VStack.
    }

    private var photoSourceButtons: some View {
        HStack(spacing: 10) {
            Button {
                showingLibrary = true
            } label: {
                photoSourceLabel(
                    icon: "photo.on.rectangle",
                    title: "Photo Library",
                )
            }
            Button {
                showingCamera = true
            } label: {
                photoSourceLabel(
                    icon: "camera.fill",
                    title: "Take Photo",
                )
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
        }
    }

    private func photoSourceLabel(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
            Text(title)
                .font(CaptainTheme.body(13, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            Capsule().fill(CaptainTheme.walnut)
                .overlay(
                    Capsule()
                        .strokeBorder(CaptainTheme.brass, lineWidth: 1)
                )
        )
    }

    private var questionBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt = item.questionPrompt {
                Text(prompt)
                    .font(CaptainTheme.body(14, weight: .medium))
                    .foregroundStyle(CaptainTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(
                "",
                text: $notes,
                prompt: Text(item.placeholder ?? "Your answer…")
                    .foregroundStyle(CaptainTheme.textMuted),
                axis: .vertical,
            )
            .font(CaptainTheme.body(15))
            .foregroundStyle(CaptainTheme.textPrimary)
            .lineLimit(3...8)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(CaptainTheme.creamDeep)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        CaptainTheme.brass.opacity(0.3), lineWidth: 1,
                    )
            )
            .onChange(of: notes) { _, newValue in
                if newValue.count > maxNoteLength {
                    notes = String(newValue.prefix(maxNoteLength))
                }
            }
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        Button(action: { Task { await submit() } }) {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                }
                Text(submitLabel)
                    .font(CaptainTheme.display(16))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    canSubmit
                        ? CaptainTheme.walnut
                        : CaptainTheme.walnut.opacity(0.3)
                )
                .overlay(
                    Capsule().strokeBorder(
                        CaptainTheme.brass,
                        lineWidth: canSubmit ? 1 : 0,
                    )
                )
            )
        }
        .disabled(!canSubmit)
    }

    private var submitLabel: String {
        item.status == "done" ? "save changes" : "save"
    }

    /// Skip / not-applicable / reset depending on current status.
    private var secondaryActions: some View {
        HStack(spacing: 14) {
            if item.status == "done" {
                Button { Task { await reset() } } label: {
                    secondaryButtonLabel(
                        icon: "arrow.uturn.left",
                        title: "Redo from scratch",
                    )
                }
            } else {
                Button { Task { await skip() } } label: {
                    secondaryButtonLabel(
                        icon: "clock",
                        title: "Skip for now",
                    )
                }
                Button { Task { await notApplicable() } } label: {
                    secondaryButtonLabel(
                        icon: "minus.circle",
                        title: "Doesn't apply",
                    )
                }
            }
        }
    }

    private func secondaryButtonLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .font(CaptainTheme.body(13, weight: .medium))
        }
        .foregroundStyle(CaptainTheme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .overlay(
            Capsule()
                .strokeBorder(
                    CaptainTheme.textMuted.opacity(0.3), lineWidth: 1
                )
        )
    }

    // MARK: - Network

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let updated = try await CaptainAPI.completeHuntItem(
                item.id,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                photo: photoData,
            )
            onUpdated(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func skip() async {
        await runAction { try await CaptainAPI.skipHuntItem(item.id) }
    }

    private func notApplicable() async {
        await runAction {
            try await CaptainAPI.huntItemNotApplicable(item.id)
        }
    }

    private func reset() async {
        await runAction { try await CaptainAPI.resetHuntItem(item.id) }
    }

    private func runAction(
        _ action: () async throws -> HuntResponse,
    ) async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let updated = try await action()
            onUpdated(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
