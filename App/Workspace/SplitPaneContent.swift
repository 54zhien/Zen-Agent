import SwiftUI

@MainActor
struct SplitEmptyPanePicker: View {
    let summaries: [RecentConversationSummary]
    let occupiedID: String
    let errorMessage: String?
    let hasMore: Bool
    let onLoadMore: () -> Void
    let onRetry: () -> Void
    let onOpen: (String) -> Void
    let onNew: () -> Void

    private var choices: [RecentConversationSummary] {
        Array(summaries.filter { $0.id != occupiedID }.reversed())
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                VStack(alignment: .leading, spacing: 12) {
                    Text("选择会话")
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.white)
                        Button("重试列表", action: onRetry)
                    }
                    if hasMore {
                        Button("更早的会话", action: onLoadMore)
                            .accessibilityIdentifier("split-history-more")
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(choices) { summary in
                                Button { onOpen(summary.id) } label: {
                                    Text(summary.title)
                                        .lineLimit(4)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                                               alignment: .topLeading)
                                        .padding(12)
                                }
                                .accessibilityIdentifier("split-history-\(summary.id)")
                                .frame(width: cardWidth(in: geometry), height: min(170, geometry.size.height * 0.55))
                                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18))
                            }
                            Button(action: onNew) {
                                Text("新会话")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                                           alignment: .topLeading)
                                    .padding(12)
                            }
                            .accessibilityIdentifier("split-new-conversation")
                            .frame(width: cardWidth(in: geometry), height: min(170, geometry.size.height * 0.55))
                            .background(Color(white: 0.21), in: RoundedRectangle(cornerRadius: 18))
                            .id("split-new")
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .onAppear { reader.scrollTo("split-new", anchor: .trailing) }
            }
        }
        .background(Color(white: 0.09))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("split-empty-pane-picker")
    }

    private func cardWidth(in geometry: GeometryProxy) -> CGFloat {
        max(80, (geometry.size.width - 40) / 3)
    }
}

@MainActor
struct SplitSecondaryPaneView: View {
    let model: AppShellModel
    var body: some View {
        NewConversationView(model: model, surfaceSlot: model.sourceSurfaceSlot.other)
    }
}
