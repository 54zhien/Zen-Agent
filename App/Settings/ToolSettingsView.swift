import SwiftUI

@MainActor
struct ToolSettingsView: View {
    let model: ToolSettingsModel

    var body: some View {
        Form {
            Section {
                Text("长期策略在每次调用时重新检查。授权不会替代 iOS 权限，也不会自动恢复正在等待的调用。")
                    .foregroundStyle(.secondary)
                Text(capDescription)
            }
            if model.actions.isEmpty {
                Section {
                    Text("当前没有可调用工具。已有授权仍可查看和撤销。")
                        .accessibilityIdentifier("settings-tools-unavailable")
                }
            }
            ForEach(model.actions) { row in
                Section {
                    Picker("长期策略", selection: Binding(get: { row.policy.mode }, set: { mode in
                        Task { _ = await model.setPolicy(toolID: row.toolID, actionID: row.action.actionID,
                            descriptorRevision: row.action.descriptorRevision, mode: mode) }
                    })) {
                        Text("始终允许").tag(ToolPersistentPolicy.alwaysAllow)
                        Text("每次询问").tag(ToolPersistentPolicy.askEveryTime)
                        Text("禁止").tag(ToolPersistentPolicy.deny)
                    }
                    .accessibilityIdentifier("tool-policy-\(row.toolID)-\(row.action.actionID)")
                    .disabled(model.isWorking)
                    LabeledContent("系统权限", value: systemDescription(row.systemState))
                    Text(actionDescription(row.action)).foregroundStyle(.secondary)
                } header: {
                    Text("\(row.displayName) · \(actionTitle(row.action.actionID))")
                } footer: {
                    Text("动作：\(row.action.actionID) · 版本：\(row.action.descriptorRevision)")
                }
            }
            Section("授权记录") {
                if model.grants.isEmpty { Text("暂无授权记录").foregroundStyle(.secondary) }
                ForEach(model.grants) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(row.grant.toolID) · \(actionTitle(row.grant.actionID))")
                        Text(subjectDescription(row.grant))
                        Text("动作版本：\(row.grant.descriptorRevision)")
                        Text(resourceDescription(row.grant.resource))
                        Text(destinationDescription(row.grant.destination))
                        Text(validityDescription(row.grant.validity)).foregroundStyle(.secondary)
                        if let reason = row.invalidationReason { Text(reason).foregroundStyle(.secondary) }
                        if row.grant.validity == .active {
                            Button("撤销授权", role: .destructive) {
                                Task { _ = await model.revokeGrant(id: row.id) }
                            }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("tool-revoke-\(row.id)")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("重试读取") { Task { await model.load() } }
                }
            }
        }
        .navigationTitle("可调用工具")
        .settingsCloseToolbar()
        .accessibilityIdentifier("settings-tools-page")
        .task { await model.load() }
    }

    private var capDescription: String {
        switch model.safetyCap {
        case .unrestricted: "当前安全上限允许按动作策略检查。"
        case .requiresExplicitApproval: "当前安全上限要求逐次明确批准。"
        case .deny: "当前安全上限禁止工具执行。"
        case .unknown: "安全上限不可用，工具将拒绝执行。"
        }
    }

    private func actionDescription(_ action: ToolPolicyActionMetadata) -> String {
        if action.requiresExplicitApproval { return "此动作仍需明确批准；长期允许不会跳过确认。" }
        if !action.allowsAutomaticApproval { return "此动作不支持自动批准。" }
        return "仅满足当前安全策略、资源与目标检查时，才可自动执行。"
    }

    private func actionTitle(_ action: String) -> String {
        switch action {
        case "read": "读取"
        case "create": "创建"
        case "modify": "修改"
        case "delete": "删除"
        default: action
        }
    }

    private func systemDescription(_ state: ToolSystemPermissionState?) -> String {
        switch state {
        case .notRequired: "无需额外 iOS 权限"
        case .authorized: "系统已允许"
        case .notDetermined: "尚未决定；调用时另行征求同意"
        case .denied: "系统已拒绝"
        case .restricted: "系统限制"
        case .unavailable: "当前不可用"
        case nil: "按具体调用检查"
        }
    }

    private func subjectDescription(_ grant: ToolScopedGrant) -> String {
        let owner: String
        switch grant.subject {
        case .parentConversation(let id): owner = "会话：\(id)"
        case .run(let id): owner = "Run：\(id)"
        }
        switch grant.kind {
        case .conversation: return "允许本会话 · \(owner)"
        case .once(let call, _, _): return "仅本次调用：\(call) · \(owner)"
        }
    }

    private func resourceDescription(_ resource: ToolResourceScope) -> String {
        switch resource {
        case .notRequired: "无需资源范围"
        case .missing: "资源范围不可用"
        case .target(let id): "目标：\(id)"
        case .file(let asset, let version, let digest):
            "文件：\(asset)\n版本：\(version)\n内容标识：\(digest)"
        }
    }

    private func destinationDescription(_ destination: ToolDestinationScope) -> String {
        switch destination {
        case .notRequired: "无需外发目标"
        case .missing: "外发目标不可用"
        case .provider(let id, let endpoint): "Provider：\(id)\n目标：\(endpoint)"
        }
    }

    private func validityDescription(_ validity: ToolGrantValidity) -> String {
        switch validity {
        case .active: "记录有效；实际调用仍会重新检查。"
        case .revoked: "已撤销"
        case .consumed: "已消费或调用已结束"
        }
    }
}
