import PhotosUI
import SwiftUI

@MainActor
struct ComposerImageAttachmentPicker: View {
    let service: ManagedImageAttachmentService
    let onImported: (AttachmentReference) -> Void
    let onImportFailure: () -> Void

    @State private var selection: [PhotosPickerItem] = []
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if isImporting {
                ProgressView("正在添加图片")
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("composer-image-import-progress")
            } else {
                PhotosPicker(selection: $selection, maxSelectionCount: nil, matching: .images) {
                    Label("选择图片", systemImage: "photo")
                        .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer-image-picker")
            }
        }
        .onChange(of: selection) { _, selectedItems in
            guard !selectedItems.isEmpty else { return }
            beginImport(selectedItems)
        }
        .onDisappear {
            importTask?.cancel()
        }
    }

    private func beginImport(_ selectedItems: [PhotosPickerItem]) {
        importTask?.cancel()
        selection = []
        isImporting = true
        importTask = Task {
            defer {
                isImporting = false
                importTask = nil
            }
            for item in selectedItems {
                do {
                    let attachment = try await service.importPhoto(item)
                    guard !Task.isCancelled else {
                        try await service.discardUnreferenced(attachment)
                        return
                    }
                    onImported(attachment)
                } catch is CancellationError {
                    return
                } catch {
                    onImportFailure()
                    return
                }
            }
        }
    }
}
