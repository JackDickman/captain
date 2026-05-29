import PhotosUI
import SwiftUI
import UIKit

/// Document upload sheet for the scavenger hunt. Lets the user photo-
/// graph an inspection report, seller's disclosure, closing docs, or
/// appliance manuals — Captain skims them with a vision LLM and
/// pre-fills hunt items so the tour goes faster.
///
/// The pre-fill never auto-completes anything. Items come back with
/// notes pre-populated and a `notes_source = "documents"` badge; the
/// user still taps through each one to confirm, edit, or supersede.
struct HuntDocumentsView: View {
    /// Called with the updated HuntResponse so the parent (HuntView)
    /// can refresh and dismiss this sheet cleanly.
    let onProcessed: (HuntResponse) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photoData: [Data] = []
    @State private var showingLibrary = false
    @State private var showingCamera = false
    @State private var isProcessing = false
    @State private var errorMessage: String?

    /// Soft cap so a user doesn't accidentally try to upload an entire
    /// 30-page inspection report at full resolution. They can re-run
    /// the flow for additional batches.
    private let maxDocs = 10

    private var canUpload: Bool {
        !photoData.isEmpty && !isProcessing
    }

    var body: some View {
        ZStack {
            CaptainTheme.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if isProcessing {
                    processingView
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            intro
                            if !photoData.isEmpty { pendingStrip }
                            sourceButtons
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(CaptainTheme.body(12))
                                    .foregroundStyle(CaptainTheme.rust)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            uploadButton
                            Color.clear.frame(height: 24)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }
                    .captainScrollEdgeFade()
                }
            }
        }
        .photosPicker(
            isPresented: $showingLibrary,
            selection: $photoItems,
            maxSelectionCount: max(1, maxDocs - photoData.count),
            selectionBehavior: .ordered,
            matching: .images
        )
        .onChange(of: photoItems) { _, newItems in
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
                photoData = Array(combined.prefix(maxDocs))
                photoItems = []
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { data in
                guard photoData.count < maxDocs else { return }
                photoData.append(data)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if !isProcessing { dismiss() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CaptainTheme.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(CaptainTheme.creamDeep))
            }
            .disabled(isProcessing)
            Text("Got docs?")
                .font(CaptainTheme.display(17))
                .foregroundStyle(CaptainTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(CaptainTheme.cream)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "If you have your inspection report, seller's disclosure, "
                + "closing docs, or appliance manuals, snap a few photos "
                + "now. Captain will skim them and pre-fill what it can — "
                + "you just confirm or tweak each one."
            )
                .font(CaptainTheme.body(14))
                .foregroundStyle(CaptainTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Nothing is auto-completed without your tap. You can also "
                + "skip this and walk the tour from scratch."
            )
                .font(CaptainTheme.body(12))
                .foregroundStyle(CaptainTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pendingStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(photoData.count) of \(maxDocs) ready to upload")
                .font(CaptainTheme.label(11))
                .foregroundStyle(CaptainTheme.textMuted)
                .tracking(1.0)
                .textCase(.uppercase)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(
                        Array(photoData.enumerated()), id: \.offset
                    ) { idx, data in
                        if let img = UIImage(data: data) {
                            pendingChip(image: img, index: idx)
                        }
                    }
                }
            }
        }
    }

    private func pendingChip(image: UIImage, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            CaptainTheme.brass.opacity(0.5), lineWidth: 1
                        )
                )
            Button {
                if index < photoData.count { photoData.remove(at: index) }
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

    private var sourceButtons: some View {
        HStack(spacing: 10) {
            Button {
                showingLibrary = true
            } label: {
                sourceLabel(
                    icon: "photo.on.rectangle",
                    title: "Photo Library",
                )
            }
            .disabled(photoData.count >= maxDocs)

            Button {
                showingCamera = true
            } label: {
                sourceLabel(icon: "camera.fill", title: "Take Photo")
            }
            .disabled(
                photoData.count >= maxDocs
                || !UIImagePickerController.isSourceTypeAvailable(.camera)
            )
        }
    }

    private func sourceLabel(icon: String, title: String) -> some View {
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

    private var uploadButton: some View {
        Button(action: { Task { await upload() } }) {
            HStack(spacing: 8) {
                Text(canUpload ? "Upload & extract" : "Add a photo first")
                    .font(CaptainTheme.display(16))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(
                    canUpload
                        ? CaptainTheme.walnut
                        : CaptainTheme.walnut.opacity(0.3)
                )
                .overlay(
                    Capsule().strokeBorder(
                        CaptainTheme.brass,
                        lineWidth: canUpload ? 1 : 0,
                    )
                )
            )
        }
        .disabled(!canUpload)
    }

    /// Full-bleed "Captain is reading…" while the extraction runs.
    /// LLM call can take 30-90s for multi-page reports.
    private var processingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .tint(CaptainTheme.brass)
                .controlSize(.large)
            Text("Captain is reading your docs…")
                .font(CaptainTheme.display(18))
                .foregroundStyle(CaptainTheme.textPrimary)
            Text("This can take a minute for multi-page reports.")
                .font(CaptainTheme.body(13))
                .foregroundStyle(CaptainTheme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Network

    private func upload() async {
        guard canUpload else { return }
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }
        do {
            let updated = try await CaptainAPI.uploadHuntDocuments(photoData)
            onProcessed(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
