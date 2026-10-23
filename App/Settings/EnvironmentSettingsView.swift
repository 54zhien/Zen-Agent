import SwiftUI

@MainActor
struct EnvironmentSettingsView: View {
    let model: EnvironmentSettingsModel
    let focus: SettingsInputFocus
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                Text("全局变量为技能提供默认值，技能范围的变量只覆盖对应技能。密钥是执行配置，不会发送到模型。")
                    .foregroundStyle(.secondary)
            }
            if model.isLoaded {
                Section("变量") {
                    if model.items.isEmpty {
                        Text("暂无环境变量").foregroundStyle(.secondary).accessibilityIdentifier("environment-empty")
                    }
                    ForEach(model.items) { item in
                        NavigationLink {
                            EnvironmentEditorView(model: model, item: item, focus: focus)
                        } label: {
                            EnvironmentListLabel(item: item,
                                                 skillName: item.scope.skillID.flatMap { model.skillName(id: $0) })
                        }
                        .accessibilityIdentifier("environment-variable-\(item.id)")
                    }
                }
                if let skillListError = model.skillListErrorMessage {
                    Section { Text(skillListError).foregroundStyle(.secondary) }
                }
                if let status = model.statusMessage {
                    Section { Text(status).foregroundStyle(.secondary).accessibilityIdentifier("environment-status") }
                }
            } else if model.errorMessage == nil {
                Section { ProgressView("正在读取环境变量") }
            }
            if let cleanupMessage = model.cleanupStatusMessage {
                Section("密钥清理") {
                    Text(cleanupMessage).foregroundStyle(.secondary)
                        .accessibilityIdentifier("environment-pending-cleanup")
                    Button("重试清理") { Task { await model.retryCredentialCleanup() } }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("environment-cleanup-retry")
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("重试读取") { Task { await model.load() } }
                        .accessibilityIdentifier("environment-retry")
                }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle("环境变量")
        .settingsCloseToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { Task { await model.load() } }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("environment-refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加") { isAdding = true }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("environment-add")
            }
        }
        .navigationDestination(isPresented: $isAdding) {
            EnvironmentEditorView(model: model, item: nil, focus: focus)
        }
        .task { await model.load() }
    }
}

@MainActor
private struct EnvironmentListLabel: View {
    let item: EnvironmentItem
    let skillName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(item.key).foregroundStyle(.primary)
                Text(item.scope.skillID == nil ? "全局" : (skillName ?? "技能不可用"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(valueDescription)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if item.pendingDeletion {
                Text("等待相关运行停止后删除").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var valueDescription: String {
        switch item.value {
        case .plain(let value): value.isEmpty ? "普通文本 · 空值" : "普通文本 · 已保存"
        case .secret: "密钥 · 已保存"
        }
    }
}

private enum EnvironmentEditorKind: String, CaseIterable, Identifiable, Hashable {
    case plain
    case secret

    var id: Self { self }
    var title: String { self == .plain ? "普通文本" : "密钥" }
}

@MainActor
private struct EnvironmentEditorView: View {
    let model: EnvironmentSettingsModel
    let item: EnvironmentItem?
    let focus: SettingsInputFocus
    @Environment(\.dismiss) private var dismiss
    @State private var scope: EnvironmentScope
    @State private var key: String
    @State private var kind: EnvironmentEditorKind
    @State private var plainValue: String
    @State private var secretText = ""
    @State private var deletionSummary: ExtensionDependencySummary?
    @State private var isConfirmingDelete = false
    @State private var isPreparingDelete = false
    @State private var expectedRevisionID: String?

    init(model: EnvironmentSettingsModel, item: EnvironmentItem?, focus: SettingsInputFocus) {
        self.model = model
        self.item = item
        self.focus = focus
        _expectedRevisionID = State(initialValue: item?.revisionID)
        _scope = State(initialValue: item?.scope ?? .global)
        _key = State(initialValue: item?.key ?? "")
        switch item?.value {
        case .plain(let value):
            _kind = State(initialValue: .plain)
            _plainValue = State(initialValue: value)
        case .secret:
            _kind = State(initialValue: .secret)
            _plainValue = State(initialValue: "")
        case nil:
            _kind = State(initialValue: .plain)
            _plainValue = State(initialValue: "")
        }
    }

    private var currentItem: EnvironmentItem? { item.flatMap { model.item(id: $0.id) } ?? item }
    private var isPendingDeletion: Bool { currentItem?.pendingDeletion == true }
    private var isExistingSecret: Bool {
        guard let currentItem else { return false }
        if case .secret = currentItem.value { return true }
        return false
    }

    var body: some View {
        Form {
            Section("变量身份") {
                if let item {
                    LabeledContent("作用范围", value: scopeTitle(item.scope))
                    LabeledContent("键", value: item.key)
                    Text("作用范围和键是固定身份；要更换它们，请先删除此变量，再创建新变量。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker("作用范围", selection: $scope) {
                        Text("全局").tag(EnvironmentScope.global)
                        ForEach(model.skills.filter { !$0.pendingDeletion }) { skill in
                            Text(skill.definition.name).tag(EnvironmentScope.skill(skill.id))
                        }
                    }
                    .accessibilityIdentifier("environment-scope")
                    if let error = model.skillListErrorMessage {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("键") {
                        SettingsTextField(text: $key, title: "例如 SERVICE_TOKEN", focus: focus,
                                          identifier: "environment-key")
                    }
                }
                if isPendingDeletion {
                    Text("此变量正在等待相关运行安全停止。完成前配置可能仍被冻结运行引用。")
                        .foregroundStyle(.orange).accessibilityIdentifier("environment-pending-deletion")
                }
            }
            Section("值") {
                Picker("类型", selection: $kind) {
                    ForEach(EnvironmentEditorKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                .disabled(isPendingDeletion)
                .accessibilityIdentifier("environment-kind")
                if kind == .plain {
                    if isPendingDeletion {
                        Text(plainValue.isEmpty ? "空值" : plainValue).textSelection(.enabled)
                    } else {
                        SettingsInstructionsInput(text: $plainValue, focus: focus,
                                                  accessibilityLabel: "普通文本值",
                                                  accessibilityIdentifier: "environment-plain-value")
                            .frame(minHeight: 120)
                    }
                } else {
                    if isExistingSecret {
                        Text("已有密钥不会显示。输入新值可替换；留空会保留现有密钥。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("密钥仅供可信执行边界使用，不会发送到模型。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if isPendingDeletion {
                        Text("已有密钥不会显示。此变量正在等待删除。")
                            .foregroundStyle(.secondary)
                    } else {
                        SettingsTextField(text: $secretText, title: "输入新密钥", focus: focus,
                                          secure: true, identifier: "environment-secret-value")
                    }
                }
            }
            if let currentItem {
                Section("依赖") {
                    LabeledContent("正在使用的运行", value: runCountText)
                    if let names = deletionSummary?.skillNames, !names.isEmpty {
                        LabeledContent("声明此键的技能", value: names.joined(separator: "、"))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button(currentItem.pendingDeletion ? "重试删除变量" : "删除变量", role: .destructive) {
                        prepareDelete(currentItem)
                    }
                    .disabled(model.isBusy || isPreparingDelete)
                    .accessibilityIdentifier("environment-delete")
                }
            }
            if let status = model.statusMessage {
                Section { Text(status).foregroundStyle(.secondary).accessibilityIdentifier("environment-save-status") }
            }
            if let cleanup = model.cleanupStatusMessage {
                Section("密钥清理") {
                    Text(cleanup).foregroundStyle(.secondary)
                    Button("重试清理") { Task { await model.retryCredentialCleanup() } }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("environment-cleanup-retry")
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(item == nil ? "新建变量" : "环境变量")
        .settingsCloseToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .disabled(model.isBusy || focus.hasMarkedText || isPendingDeletion)
                    .accessibilityIdentifier("environment-save")
            }
        }
        .confirmationDialog("删除环境变量？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("确认删除变量", role: .destructive) {
                guard let currentItem else { return }
                Task { if await model.delete(id: currentItem.id) { dismiss() } }
            }
            .accessibilityIdentifier("environment-delete-confirm")
            Button("取消", role: .cancel) { }
        } message: {
            Text(deleteMessage)
        }
        .onDisappear { secretText = "" }
    }

    private var runCountText: String {
        guard let deletionSummary else { return "删除前会检查依赖运行" }
        let count = deletionSummary.activeRunIDs.count
        return count == 0 ? "0 个" : "\(count) 个，确认后将停止"
    }

    private var deleteMessage: String {
        let summary = deletionSummary ?? ExtensionDependencySummary()
        let affectedSkills = summary.skillNames.isEmpty
            ? "没有技能声明依赖此键。"
            : "受影响的技能：\(summary.skillNames.joined(separator: "、"))."
        let runCount = summary.activeRunIDs.count
        let affectedRuns = runCount == 0
            ? "没有正在使用它的运行。"
            : "将停止 \(runCount) 个正在使用它的运行。"
        return "\(affectedSkills) \(affectedRuns)"
    }

    private func scopeTitle(_ scope: EnvironmentScope) -> String {
        guard let skillID = scope.skillID else { return "全局" }
        return model.skillName(id: skillID) ?? "技能不可用"
    }

    private func prepareDelete(_ item: EnvironmentItem) {
        isPreparingDelete = true
        Task {
            if let summary = await model.dependencies(id: item.id) {
                deletionSummary = summary
                isConfirmingDelete = true
            }
            isPreparingDelete = false
        }
    }

    private func save() async {
        let saveScope = item?.scope ?? scope
        let saveKey = item?.key ?? key
        let saved: EnvironmentItem?
        switch kind {
        case .plain:
            saved = await model.savePlain(id: item?.id, expectedRevisionID: expectedRevisionID,
                                          scope: saveScope, key: saveKey, value: plainValue)
        case .secret:
            let replacement = secretText.isEmpty ? nil : SecretValue(secretText)
            saved = await model.saveSecret(id: item?.id, expectedRevisionID: expectedRevisionID,
                                           scope: saveScope, key: saveKey, value: replacement)
        }
        guard saved != nil else { return }
        expectedRevisionID = saved?.revisionID
        secretText = ""
        if item == nil { dismiss() }
    }
}
