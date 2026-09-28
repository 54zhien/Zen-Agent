import SwiftUI

@MainActor
struct ConversationPreviewView: View {
    let summary: ConversationSummary?
    var status: ConversationPreviewStatus = .ready
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(summary?.title ?? "新会话")
                .font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                .lineLimit(2)
            if let summary {
                Text(summary.excerpt)
                    .font(Typography.font(for: .conversationBody, dynamicTypeSize: dynamicTypeSize))
                    .lineLimit(8)
                if let runStatus = ConversationCardStatus.derive(from: summary.runProjection) {
                    Text(runStatus.label)
                        .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                        .foregroundStyle(.secondary)
                }
            }
            switch status {
            case .restoring: ProgressView("正在打开会话")
            case .contentUnavailable: Text("部分内容暂不可用")
            case .failed(let message): Text(message)
            case .ready, .migrationRequired: EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
    }
}

extension ConversationCardStatus {
    var label: String {
        switch self {
        case .generating: "生成中"
        case .reasoningVisible: "思考中"
        case .tool: "工具运行中"
        case .approval: "等待批准"
        case .cancelled: "已取消"
        case .failed: "运行失败"
        case .authenticationRequired: "需要重新验证凭据"
        }
    }
}
