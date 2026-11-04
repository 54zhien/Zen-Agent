import SwiftUI
import UIKit

@MainActor
struct ImageAttachmentThumbnailView: View {
    let attachment: AttachmentReference
    let service: ManagedImageAttachmentService?
    var onRemove: (() -> Void)? = nil

    @State private var thumbnail: UIImage?
    @State private var isLoading = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnailContent
                .frame(width: 68, height: 68)
                .background(Color(uiColor: .secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize)
                            .weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除图片")
                .accessibilityIdentifier("remove-image-attachment-\(attachment.id)")
                .offset(x: 7, y: -7)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.displayName)
        .accessibilityIdentifier("image-attachment-thumbnail-\(attachment.id)")
        .task(id: "\(attachment.id):\(attachment.versionID)") {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else if isLoading {
            ProgressView()
                .accessibilityLabel("正在读取图片")
        } else {
            Image(systemName: "photo")
                .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(.secondary)
                .accessibilityLabel("图片不可用")
        }
    }

    private func loadThumbnail() async {
        guard let service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await service.thumbnailData(for: attachment)
            guard !Task.isCancelled else { return }
            thumbnail = data.flatMap(UIImage.init(data:))
        } catch {
            guard !Task.isCancelled else { return }
            thumbnail = nil
        }
    }
}
