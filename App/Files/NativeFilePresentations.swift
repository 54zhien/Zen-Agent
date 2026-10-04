import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct NativeFilePicker: UIViewControllerRepresentable {
    enum Mode { case importFile, export(ManagedFilePresentation) }
    let mode: Mode
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(mode: mode, onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller: UIDocumentPickerViewController
        switch mode {
        case .importFile:
            controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            controller.allowsMultipleSelection = false
        case .export(let copy):
            controller = UIDocumentPickerViewController(forExporting: [copy.url], asCopy: true)
            controller.view.accessibilityIdentifier = "files-native-export"
        }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        // The native picker retains its immutable export source until its actual dismissal.
        let mode: Mode
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        private var finished = false
        init(mode: Mode, onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.mode = mode; self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !finished else { return }
            finished = true
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !finished else { return }
            finished = true; onCancel()
        }
    }
}

@MainActor
struct NativeFilePreview: UIViewControllerRepresentable {
    let copy: ManagedFilePresentation
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(copy: copy, onClose: onClose) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator; preview.delegate = context.coordinator
        let navigation = UINavigationController(rootViewController: preview)
        preview.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
            target: context.coordinator, action: #selector(Coordinator.done))
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let copy: ManagedFilePresentation
        let onClose: () -> Void
        init(copy: ManagedFilePresentation, onClose: @escaping () -> Void) {
            self.copy = copy; self.onClose = onClose
        }
        @objc func done() { onClose() }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            copy.url as NSURL
        }
        nonisolated func previewController(_ controller: QLPreviewController,
                               editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
        nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
            // Quick Look's delegate requirement is nonisolated in this SDK. Only
            // the captured presentation owner may close its MainActor overlay.
            Task { @MainActor [weak self] in self?.onClose() }
        }
    }
}
