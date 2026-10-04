import SwiftUI

@MainActor
struct ConversationSearchView: View {
    @Bindable var model: ConversationSearchModel
    let onClose: () -> Void
    let onSelect: (String) -> Void
    @State private var inputFocus = SearchQueryFocus()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("搜索会话").font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                if model.query.split(whereSeparator: \.isWhitespace).isEmpty {
                    Text("按会话标题搜索").foregroundStyle(.secondary)
                } else if model.items.isEmpty, !model.isLoading, model.errorMessage == nil {
                    Text("没有匹配的会话").foregroundStyle(.secondary)
                }
                ForEach(model.items) { summary in
                    Button { onSelect(summary.id) } label: {
                        HStack(alignment: .top, spacing: 16) {
                            // Metadata projection only; never instantiate a live Pane.
                            Text(summary.excerpt.isEmpty ? summary.title : String(summary.excerpt.prefix(100)))
                            .font(.system(size: 6)).lineLimit(5)
                            .foregroundStyle(.secondary)
                            .padding(7).frame(width: 44, height: 58, alignment: .topLeading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                highlightedTitle(summary.title)
                                if summary.contentUnavailable {
                                    Text("部分内容暂不可用").font(.caption).foregroundStyle(.secondary)
                                }
                                if summary.pinned { Label("已置顶", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                            if model.selectedID == summary.id { ProgressView() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("conversation-search-result-\(summary.id)")
                }
                if model.isLoading { ProgressView() }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { if model.hasMore { await model.loadMore() } else { await model.refresh() } } }
                } else if model.hasMore {
                    Button("加载更多") { Task { await model.loadMore() } }
                }
                if let error = model.selectionError { Text(error).foregroundStyle(.red) }
            }
            .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
            .padding(24).padding(.top, 20)
        }
        .scrollDismissesKeyboard(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                SearchQueryInput(text: model.query,
                    font: Typography.uiFont(for: .interfaceBody, compatibleWith: UITraitCollection(
                        preferredContentSizeCategory: Typography.contentSizeCategory(for: dynamicTypeSize))),
                    focus: inputFocus, onText: { model.query = $0 })
                    .frame(maxWidth: .infinity)
                    .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("conversation-search-input")
                Button { inputFocus.release(then: onClose) } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("退出搜索").accessibilityIdentifier("conversation-search-close")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(uiColor: .systemBackground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
#if DEBUG
        .background(SearchKeyboardProbe().ignoresSafeArea(.keyboard, edges: .bottom))
#endif
        .task(id: model.query) { await model.refresh() }
        .onDisappear { inputFocus.cancel(); model.invalidate() }
    }

    private func highlightedTitle(_ title: String) -> Text {
        let query = PersistenceStore.summaryText(model.query)
        guard !query.isEmpty, let range = title.range(of: query, options: .caseInsensitive) else { return Text(title) }
        return Text(String(title[..<range.lowerBound]))
            + Text(String(title[range])).bold().foregroundColor(.accentColor)
            + Text(String(title[range.upperBound...]))
    }
}
