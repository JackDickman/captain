import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around UIImagePickerController in camera mode.
///
/// SwiftUI doesn't ship a native in-app camera component; PhotosPicker
/// covers the library and AVFoundation is overkill for "let the user
/// take a quick photo." UIImagePickerController is one shot per
/// presentation — the user takes a picture (or cancels) and the
/// picker dismisses. Re-opening the picker takes another shot, so the
/// user can capture multiple photos by repeating the action.
struct CameraPicker: UIViewControllerRepresentable {
    /// Invoked with the JPEG bytes of the captured photo. Not called
    /// on cancel.
    let onImageCaptured: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController, context: Context,
    ) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject,
        UIImagePickerControllerDelegate,
        UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info:
                [UIImagePickerController.InfoKey: Any],
        ) {
            // JPEG at 0.9 quality — the server-side compressForUpload
            // step would re-encode anyway, but this keeps the original
            // raw close to the user's expectation.
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                parent.onImageCaptured(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(
            _ picker: UIImagePickerController,
        ) {
            parent.dismiss()
        }
    }
}
