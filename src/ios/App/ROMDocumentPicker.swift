import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Lets the user pick ROM files (.wua/.wud/.rpx/.iso) from Files, iCloud
/// Drive, or any other document provider, instead of having to manually drop
/// them into the app's sandbox via the Files app.
struct ROMDocumentPicker: UIViewControllerRepresentable {
    var onPicked: ([URL]) -> Void

    /// These extensions aren't registered system UTIs, so each is declared as
    /// a dynamic type conforming to `.data` — this reliably filters the
    /// picker by extension without requiring any Info.plist UTI declarations.
    static let romContentTypes: [UTType] = ["wua", "wud", "rpx", "iso"]
        .compactMap { UTType(filenameExtension: $0, conformingTo: .data) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.romContentTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([URL]) -> Void

        init(onPicked: @escaping ([URL]) -> Void) {
            self.onPicked = onPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPicked(urls)
        }
    }
}
