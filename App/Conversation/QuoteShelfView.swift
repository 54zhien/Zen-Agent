import SwiftUI
import UIKit

struct QuoteShelfEntry: Identifiable, Equatable {
    let id: String
    let snapshot: String
    let sourceDescription: String

    init(_ reference: QuoteReference) {
        id = reference.id
        snapshot = reference.snapshot
        sourceDescription = Self.sourceDescription(reference.source)
    }

    init(_ presentation: QuoteReferencePresentation) {
        let reference = presentation.reference
        id = reference.id
        snapshot = reference.snapshot
        if presentation.sourceIsAvailable {
            sourceDescription = "\(reference.sourceConversationID) · \(reference.sourceMessageID) · \(reference.sourcePartID)"
        } else {
            sourceDescription = "原文已不可用 · \(reference.sourceMessageID)"
        }
    }

    private static func sourceDescription(_ source: QuoteSourceLocator) -> String {
        "\(source.sourceConversationID) · \(source.sourceMessageID) · \(source.sourcePartID)"
    }
}

struct QuoteShelfView: View {
    let entries: [QuoteShelfEntry]
    var onRemove: ((String) -> Void)? = nil
    var onMeasuredHeight: ((CGFloat) -> Void)? = nil

    @State private var isExpanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: quoteSymbolName)
                    .foregroundStyle(.secondary)
                Button {
                    isExpanded.toggle()
                } label: {
                    Group {
                        if entries.count == 1 {
                            Text(entries[0].snapshot)
                        } else {
                            Text("引用 · \(entries.count)")
                        }
                    }
                    .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entries.count == 1 ? "展开引用" : "展开 \(entries.count) 条引用")

                if let onRemove {
                    Button {
                        if let lastID = entries.last?.id { onRemove(lastID) }
                    } label: {
                        Image(systemName: "xmark")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除引用")
                }
            }

            if isExpanded {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.snapshot)
                            .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.sourceDescription)
                            .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: QuoteShelfHeightPreferenceKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(QuoteShelfHeightPreferenceKey.self) { onMeasuredHeight?($0) }
        .accessibilityElement(children: .contain)
    }

    private var quoteSymbolName: String {
        UIImage(systemName: "quote.opening") == nil ? "quote.bubble" : "quote.opening"
    }
}

private struct QuoteShelfHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
