import SwiftUI

struct ToolApprovalCardView: View {
    let approval: ToolApprovalProjection
    var isResolving = false
    let onDecision: (ToolApprovalRequest) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(approval.toolDisplayName)
                        .font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                    Text(approval.action)
                        .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
                        .foregroundStyle(.secondary)
                }

                disclosureRow(title: "目标对象") {
                    Text(approval.targetDescription)
                }

                disclosureRow(title: "关键影响") {
                    Text(approval.keyImpact)
                }

                disclosureRow(title: "授权范围") {
                    Text("仅本次调用")
                }

                disclosureRow(title: "授权对象") {
                    Text("本 Conversation 的 Parent Run")
                }

                VStack(spacing: 10) {
                    ForEach(ToolApprovalDecision.allCases, id: \.self) { decision in
                        Button(decision.title) {
                            guard !isResolving,
                                  approval.availableDecisions.contains(decision)
                            else { return }
                            let request = approval.request(for: decision)
                            onDecision(request)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(decision == .rejectOnce ? .red : .accentColor)
                        .disabled(isResolving || !approval.availableDecisions.contains(decision))
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func disclosureRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                .foregroundStyle(.secondary)
            content()
                .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
