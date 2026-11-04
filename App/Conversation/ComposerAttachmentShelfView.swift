import SwiftUI

struct ComposerAttachmentShelfView: View {
    let quoteEntries: [QuoteShelfEntry]
    let imageAttachments: [AttachmentReference]
    let imageService: ManagedImageAttachmentService?
    let onRemoveQuote: (String) -> Void
    let onRemoveImage: (AttachmentReference) -> Void
    var onMeasuredHeight: (CGFloat) -> Void = { _ in }

    @ScaledMetric(relativeTo: .body) private var sectionSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            if !quoteEntries.isEmpty {
                QuoteShelfView(entries: quoteEntries, onRemove: onRemoveQuote)
            }

            if !imageAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: sectionSpacing) {
                        ForEach(imageAttachments, id: \.id) { attachment in
                            ImageAttachmentThumbnailView(
                                attachment: attachment,
                                service: imageService,
                                onRemove: { onRemoveImage(attachment) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("composer-image-attachment-shelf")
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ComposerAttachmentShelfHeightKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(ComposerAttachmentShelfHeightKey.self, perform: onMeasuredHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-attachment-shelf")
    }
}

private struct ComposerAttachmentShelfHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
