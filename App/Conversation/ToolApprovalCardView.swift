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
                        .accessibilityIdentifier("tool-approval-target")
                }

                disclosureRow(title: "关键影响") {
                    Text(approval.keyImpact)
                        .accessibilityIdentifier("tool-approval-impact")
                }

                disclosureRow(title: "授权范围") {
                    Text(approval.scopeDescription)
                }

                disclosureRow(title: "授权对象") {
                    Text(approval.authorizationOwnerDescription)
                }

                if approval.kind == .systemPermission {
                    disclosureRow(title: "系统权限") {
                        Text(approval.systemPermissionDescription ?? "权限交互状态不可用，请停止后重新检查。")
                        if approval.systemPermissionPhase == .requesting { Text("正在等待 iOS 权限请求结果。") }
                    }
                }
                VStack(spacing: 10) {
                    ForEach(approval.availableDecisions, id: \.self) { decision in
                        Button(decision.title) {
                            guard !isResolving,
                                  approval.availableDecisions.contains(decision)
                            else { return }
                            let request = approval.request(for: decision)
                            onDecision(request)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(decision == .rejectOnce || decision == .declineSystemPermission ? .red : .accentColor)
                        .disabled(isResolving || !approval.availableDecisions.contains(decision))
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-approval-card")
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
