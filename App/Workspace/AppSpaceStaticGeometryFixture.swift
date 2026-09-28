#if DEBUG
import SwiftUI

@MainActor
struct AppSpaceStaticGeometryFixture: View {
    @ScaledMetric(relativeTo: .body) private var minimumWidth: CGFloat = 220
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 300
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let titles = ["阅读摘记", "一段旅程", "待解的问题", "写作草稿", "昨日的讨论", "结构与边界", "未完的想法", "当前对话"]
    private let currentIsNew = ProcessInfo.processInfo.environment["ZEN_APP_SPACE_GEOMETRY_NEW"] == "1"

    var body: some View {
        GeometryReader { viewport in
            let ids = titles.indices.map { "sample-\($0)" }
            // This reader already occupies the system-safe content area; applying
            // the same insets again would double-subtract them. The resolver's explicit
            // inset contract is exercised independently by the geometry tests.
            if let layout = AppSpaceGeometry.resolve(size: viewport.size, safeArea: .zero,
                historyIDs: ids, current: currentIsNew ? .newConversation : .conversation("sample-7"),
                minimumCardSize: CGSize(width: minimumWidth, height: minimumHeight)) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.cards, id: \.item) { card in
                        preview(card)
                            .position(x: card.frame.midX, y: card.frame.midY)
                            .zIndex(Double(3 - card.depth))
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            } else {
                Text("等待可用视口")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    private func preview(_ card: AppSpaceGeometry.Placement) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if card.item == .newConversation {
                Image(systemName: "plus")
                    .font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
            }
            Text(title(card.item))
                .font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                .lineLimit(2)
            if card.item != .newConversation {
                Text("把刚刚的讨论留在这里，下一次从同一个位置继续。")
                    .font(Typography.font(for: .conversationBody, dynamicTypeSize: dynamicTypeSize))
                    .lineLimit(card.depth == 0 ? 5 : 1)
            }
            Spacer(minLength: 0)
            Text("静态样例")
                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: card.frame.width, height: card.frame.height, alignment: .topLeading)
        .background(Color(uiColor: card.depth == 0 ? .systemBackground : .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: card.cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(card.item))
        .accessibilityIdentifier(card.depth == 0 ? "app-space-card-current" : "app-space-card-history-\(card.depth)")
    }

    private func title(_ item: AppSpaceGeometry.Item) -> String {
        switch item {
        case .newConversation: return "新对话"
        case let .conversation(id):
            let index = Int(id.dropFirst("sample-".count)) ?? 0
            return titles[index]
        }
    }
}
#endif
