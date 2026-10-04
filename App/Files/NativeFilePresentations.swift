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

    func makeUIViewController(context: Context) -> Presenter {
        Presenter(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: Presenter, context: Context) {}

    static func dismantleUIViewController(_ controller: Presenter, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Presenter: UIViewController {
        private let coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            coordinator.present(from: self)
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        // This owner survives native dismissal and retains the immutable export
        // source even when the Files overlay is removed during presentation.
        let mode: Mode
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        private var picker: UIDocumentPickerViewController?
        private var started = false
        private var isPresenting = false
        private var finished = false
        private var invalidated = false
        init(mode: Mode, onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.mode = mode; self.onPick = onPick; self.onCancel = onCancel
        }

        func present(from presenter: UIViewController) {
            guard !started, !finished, presenter.view.window != nil else { return }
            started = true
            let controller: UIDocumentPickerViewController
            switch mode {
            case .importFile:
                controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
                controller.allowsMultipleSelection = false
                controller.view.accessibilityIdentifier = "files-native-import"
            case .export(let copy):
                controller = UIDocumentPickerViewController(forExporting: [copy.url], asCopy: true)
                controller.view.accessibilityIdentifier = "files-native-export"
            }
            controller.delegate = self
            picker = controller
            // A document picker owns its native remote browser and bar geometry.
            // Present it as a UIKit modal, rather than embedding it as sheet content.
            isPresenting = true
            presenter.present(controller, animated: true) { [self] in
                isPresenting = false
                if invalidated { dismissInvalidatedPicker() }
            }
            controller.presentationController?.delegate = self
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(controller, url: urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
#if DEBUG
            if ProcessInfo.processInfo.environment["ZEN_PREVIEW_HANDOFF_UI_TEST"] == "1" {
                print("FILES_NATIVE_PICKER_CANCEL received finished=\(finished)")
            }
#endif
            finish(controller, url: nil)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let picker, presentationController.presentedViewController === picker else { return }
            finish(picker, url: nil)
        }

        private func finish(_ controller: UIDocumentPickerViewController, url: URL?) {
            guard !finished, picker === controller else { return }
            finished = true
            let complete = { [self] in
                picker = nil
                guard !invalidated else { return }
                if let url { onPick(url) } else { onCancel() }
            }
            if controller.presentingViewController != nil {
                controller.dismiss(animated: true, completion: complete)
            } else {
                complete()
            }
        }

        func invalidate() {
            invalidated = true
            guard !finished else { return }
            finished = true
            // Dismantling during the presentation animation must wait for its
            // completion before dismissing and releasing the copy's lease.
            guard !isPresenting else { return }
            dismissInvalidatedPicker()
        }

        private func dismissInvalidatedPicker() {
            guard let picker else { return }
            if picker.presentingViewController != nil {
                picker.dismiss(animated: false) { [self] in self.picker = nil }
            } else {
                self.picker = nil
            }
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
