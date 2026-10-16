import SwiftUI

/// The empty Pane's chooser, laid out like Safari's tab overview: a two-column
/// grid of page-shaped cards with their titles beneath, New first.
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var choices: [RecentConversationSummary] {
        summaries.filter { $0.id != occupiedID }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("选择会话")
                        .font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                    Spacer(minLength: 8)
                    if hasMore {
                        Button("更早的会话", action: onLoadMore)
                            .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("split-history-more")
                    }
                }
                if let errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(errorMessage)
                            .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                            .foregroundStyle(.secondary)
                        Button("重试列表", action: onRetry)
                            .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          alignment: .leading, spacing: 18) {
                    Button(action: onNew) {
                        SplitPickerCard(title: "新会话", isNew: true, unavailable: false)
                    }
                    .buttonStyle(SplitPickerCardStyle())
                    .accessibilityLabel("新会话")
                    .accessibilityIdentifier("split-new-conversation")
                    ForEach(choices) { summary in
                        Button { onOpen(summary.id) } label: {
                            SplitPickerCard(title: summary.title, isNew: false,
                                            unavailable: summary.contentUnavailable)
                        }
                        .buttonStyle(SplitPickerCardStyle())
                        .accessibilityLabel(summary.title)
                        .accessibilityIdentifier("split-history-\(summary.id)")
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("split-empty-pane-picker")
    }
}

/// A page-shaped thumbnail with its title underneath, as Safari shows a tab.
@MainActor
private struct SplitPickerCard: View {
    let title: String
    let isNew: Bool
    let unavailable: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(alignment: isNew ? .center : .topLeading) {
                    if isNew {
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(unavailable ? "内容暂不可读" : title)
                            .font(Typography.font(for: .conversationBody, dynamicTypeSize: dynamicTypeSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .multilineTextAlignment(.leading)
                            .padding(12)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
                }
                .aspectRatio(0.78, contentMode: .fit)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            Text(title)
                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
    }
}

private struct SplitPickerCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.25), value: configuration.isPressed)
    }
}

@MainActor
struct SplitSecondaryPaneView: View {
    let model: AppShellModel
    var body: some View {
        NewConversationView(model: model, surfaceSlot: model.sourceSurfaceSlot.other)
    }
}
