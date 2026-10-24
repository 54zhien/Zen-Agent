import SwiftUI

@MainActor
struct SkillSettingsView: View {
    let model: SkillSettingsModel
    let focus: SettingsInputFocus
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                Text("启用只表示技能可参与选择，不会扩大工具权限。实际调用仍经过现有授权策略。")
                    .foregroundStyle(.secondary)
            }
            if model.isLoaded {
                Section("技能") {
                    if model.items.isEmpty {
                        Text("暂无技能").foregroundStyle(.secondary).accessibilityIdentifier("skill-empty")
                    }
                    ForEach(model.items) { item in
                        HStack(alignment: .center, spacing: 12) {
                            NavigationLink {
                                if item.source == .builtIn {
                                    BuiltInSkillDetailView(model: model, item: item, focus: focus)
                                } else {
                                    SkillEditorView(model: model, item: item,
                                                    initialDefinition: item.definition, focus: focus)
                                }
                            } label: {
                                SkillListLabel(item: item, dependency: model.dependencyStatuses[item.id],
                                               dependencyUnavailable: model.dependencyReadFailures.contains(item.id))
                            }
                            .accessibilityIdentifier("skill-item-\(item.id)")

                            Toggle("启用 \(item.definition.name)", isOn: Binding(
                                get: { model.item(id: item.id)?.enabled ?? item.enabled },
                                set: { enabled in Task { await model.setEnabled(id: item.id, enabled: enabled) } }
                            ))
                            .labelsHidden()
                            .disabled(model.isBusy || item.pendingDeletion)
                            .accessibilityIdentifier("skill-enabled-\(item.id)")
                        }
                    }
                }
                if let status = model.statusMessage {
                    Section { Text(status).foregroundStyle(.secondary).accessibilityIdentifier("skill-status") }
                }
            } else if model.errorMessage == nil {
                Section { ProgressView("正在读取技能") }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("重试读取") { Task { await model.load() } }
                        .accessibilityIdentifier("skill-retry")
                }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle("Skills")
        .settingsCloseToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { Task { await model.load() } }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("skill-refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加") { isAdding = true }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("skill-add")
            }
        }
        .navigationDestination(isPresented: $isAdding) {
            SkillEditorView(model: model, item: nil,
                            initialDefinition: SkillDefinition(name: "", summary: "", instructions: ""),
                            focus: focus)
        }
        .task { await model.load() }
    }
}

@MainActor
private struct SkillListLabel: View {
    let item: SkillItem
    let dependency: SkillDependencyStatus?
    let dependencyUnavailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(item.definition.name).foregroundStyle(.primary)
                Text(item.source == .builtIn ? "内置" : "我的技能")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(item.definition.summary.isEmpty ? "暂无说明" : item.definition.summary)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if item.pendingDeletion {
                Text("等待安全停止后删除").font(.caption).foregroundStyle(.orange)
            } else if dependencyUnavailable {
                Text("依赖状态暂不可用").font(.caption).foregroundStyle(.secondary)
            } else if let dependency, !dependency.missing.isEmpty {
                Text("缺少依赖：\(dependency.missing.joined(separator: "、"))")
                    .font(.caption).foregroundStyle(.orange)
            } else if dependency != nil {
                Text("依赖可用").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
private struct BuiltInSkillDetailView: View {
    let model: SkillSettingsModel
    let item: SkillItem
    let focus: SettingsInputFocus
    @State private var copiedDefinition: SkillDefinition?
    @State private var isShowingCopyEditor = false

    private var currentItem: SkillItem { model.item(id: item.id) ?? item }

    var body: some View {
        Form {
            Section("技能") {
                LabeledContent("来源", value: "内置")
                LabeledContent("状态", value: currentItem.enabled ? "已启用" : "已停用")
                Text(currentItem.definition.summary.isEmpty ? "暂无说明" : currentItem.definition.summary)
                    .foregroundStyle(.secondary)
            }
            Section("指令") {
                Text(currentItem.definition.instructions.isEmpty ? "暂无指令" : currentItem.definition.instructions)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("skill-instructions-readonly")
            }
            SkillDependencySections(item: currentItem, dependency: model.dependencyStatuses[item.id],
                                    dependencyUnavailable: model.dependencyReadFailures.contains(item.id))
            Section {
                Button("复制并编辑") {
                    Task {
                        if let definition = await model.copyDefinition(id: item.id) {
                            copiedDefinition = definition
                            isShowingCopyEditor = true
                        }
                    }
                }
                .disabled(model.isBusy || currentItem.pendingDeletion)
                .accessibilityIdentifier("skill-copy")
            } footer: {
                Text("内置技能保持只读；副本保存后成为独立的用户技能。")
            }
            if currentItem.pendingDeletion {
                Section { Text("此技能正在等待安全停止后删除。")
                    .foregroundStyle(.orange).accessibilityIdentifier("skill-pending-deletion") }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(currentItem.definition.name)
        .settingsCloseToolbar()
        .navigationDestination(isPresented: $isShowingCopyEditor) {
            if let copiedDefinition {
                SkillEditorView(model: model, item: nil, initialDefinition: copiedDefinition, focus: focus)
            }
        }
    }
}

@MainActor
private struct SkillDependencySections: View {
    let item: SkillItem
    let dependency: SkillDependencyStatus?
    let dependencyUnavailable: Bool

    var body: some View {
        Section("依赖") {
            if let dependency {
                Text(dependency.isAvailable ? "必需依赖已满足" : "缺少必需依赖：\(dependency.missing.joined(separator: "、"))")
                    .foregroundStyle(dependency.isAvailable ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("skill-dependency-\(item.id)")
                ForEach(Array(dependency.notices.enumerated()), id: \.offset) { notice in
                    Text(notice.element).foregroundStyle(.secondary)
                }
            } else {
                Text(dependencyUnavailable ? "依赖状态暂不可用" : "正在读取依赖状态")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("skill-dependency-\(item.id)")
            }
            DependencyLine(title: "必需工具", values: item.definition.requiredTools)
            DependencyLine(title: "可选工具", values: item.definition.optionalTools)
            DependencyLine(title: "MCP 服务", values: item.definition.requiredMCPServers)
            DependencyLine(title: "环境变量键", values: item.definition.environmentKeys)
            DependencyLine(title: "触发词", values: item.definition.triggerTerms)
        }
    }
}

@MainActor
private struct DependencyLine: View {
    let title: String
    let values: [String]

    var body: some View {
        LabeledContent(title) {
            Text(values.isEmpty ? "无" : values.joined(separator: "、"))
                .foregroundStyle(values.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

@MainActor
private struct SkillEditorView: View {
    let model: SkillSettingsModel
    let item: SkillItem?
    let focus: SettingsInputFocus
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var summary: String
    @State private var instructions: String
    @State private var requiredTools: String
    @State private var optionalTools: String
    @State private var requiredMCPServers: String
    @State private var environmentKeys: String
    @State private var triggerTerms: String
    @State private var deletionSummary: ExtensionDependencySummary?
    @State private var isConfirmingDelete = false
    @State private var isPreparingDelete = false
    @State private var expectedRevisionID: String?

    private var currentItem: SkillItem? { item.flatMap { model.item(id: $0.id) } ?? item }
    private var isPendingDeletion: Bool { currentItem?.pendingDeletion == true }

    init(model: SkillSettingsModel, item: SkillItem?, initialDefinition: SkillDefinition,
         focus: SettingsInputFocus) {
        self.model = model
        self.item = item
        self.focus = focus
        _expectedRevisionID = State(initialValue: item?.revisionID)
        _name = State(initialValue: initialDefinition.name)
        _summary = State(initialValue: initialDefinition.summary)
        _instructions = State(initialValue: initialDefinition.instructions)
        _requiredTools = State(initialValue: initialDefinition.requiredTools.joined(separator: ", "))
        _optionalTools = State(initialValue: initialDefinition.optionalTools.joined(separator: ", "))
        _requiredMCPServers = State(initialValue: initialDefinition.requiredMCPServers.joined(separator: ", "))
        _environmentKeys = State(initialValue: initialDefinition.environmentKeys.joined(separator: ", "))
        _triggerTerms = State(initialValue: initialDefinition.triggerTerms.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("技能信息") {
                LabeledContent("来源", value: currentItem == nil ? "未保存的用户技能" : "我的技能")
                if isPendingDeletion {
                    LabeledContent("名称", value: name)
                    LabeledContent("说明", value: summary)
                } else {
                    LabeledContent("名称") {
                        SettingsTextField(text: $name, title: "名称", focus: focus, identifier: "skill-name")
                    }
                    LabeledContent("说明") {
                        SettingsTextField(text: $summary, title: "简短说明", focus: focus, identifier: "skill-summary")
                    }
                }
                if let currentItem {
                    LabeledContent("启用状态", value: currentItem.enabled ? "已启用" : "已停用")
                    if currentItem.pendingDeletion {
                        Text("此技能正在等待安全停止后删除。")
                            .foregroundStyle(.orange).accessibilityIdentifier("skill-pending-deletion")
                    }
                }
            }
            if let currentItem {
                Section("当前依赖状态") {
                    if let dependency = model.dependencyStatuses[currentItem.id] {
                        Text(dependency.isAvailable
                             ? "必需依赖已满足"
                             : "缺少必需依赖：\(dependency.missing.joined(separator: "、"))")
                            .foregroundStyle(dependency.isAvailable ? Color.secondary : Color.orange)
                            .accessibilityIdentifier("skill-dependency-\(currentItem.id)")
                        ForEach(Array(dependency.notices.enumerated()), id: \.offset) { notice in
                            Text(notice.element).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(model.dependencyReadFailures.contains(currentItem.id)
                             ? "依赖状态暂不可用" : "正在读取依赖状态")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("skill-dependency-\(currentItem.id)")
                    }
                }
            }
            Section {
                if isPendingDeletion {
                    Text(instructions).textSelection(.enabled).frame(minHeight: 180)
                } else {
                    SettingsInstructionsInput(text: $instructions, focus: focus,
                                              accessibilityLabel: "技能指令",
                                              accessibilityIdentifier: "skill-instructions")
                        .frame(minHeight: 180)
                }
            } header: {
                Text("指令")
            } footer: {
                Text("技能指令作为工作流程上下文，不会授予工具权限。")
            }
            Section("依赖与路由") {
                MetadataField(title: "必需工具", hint: "工具 ID，逗号分隔", text: $requiredTools,
                              focus: focus, identifier: "skill-required-tools", readOnly: isPendingDeletion)
                MetadataField(title: "可选工具", hint: "工具 ID，逗号分隔", text: $optionalTools,
                              focus: focus, identifier: "skill-optional-tools", readOnly: isPendingDeletion)
                MetadataField(title: "必需 MCP 服务", hint: "服务 ID，逗号分隔", text: $requiredMCPServers,
                              focus: focus, identifier: "skill-required-mcp-servers", readOnly: isPendingDeletion)
                MetadataField(title: "环境变量键", hint: "键名，逗号分隔", text: $environmentKeys,
                              focus: focus, identifier: "skill-environment-keys", readOnly: isPendingDeletion)
                MetadataField(title: "触发词", hint: "词语，逗号分隔", text: $triggerTerms,
                              focus: focus, identifier: "skill-trigger-terms", readOnly: isPendingDeletion)
                Text("当前不支持的 MCP 服务依赖会保持不可用；此处不会建立连接或导入技能。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let status = model.statusMessage {
                Section { Text(status).foregroundStyle(.secondary).accessibilityIdentifier("skill-save-status") }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            if let currentItem {
                Section {
                    Button(currentItem.pendingDeletion ? "重试删除技能" : "删除技能", role: .destructive) {
                        prepareDelete(currentItem)
                    }
                    .disabled(model.isBusy || isPreparingDelete)
                    .accessibilityIdentifier("skill-delete")
                }
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(currentItem == nil ? "新建技能" : "编辑技能")
        .settingsCloseToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .disabled(model.isBusy || focus.hasMarkedText || currentItem?.pendingDeletion == true)
                    .accessibilityIdentifier("skill-save")
            }
        }
        .confirmationDialog("删除用户技能？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("确认删除技能", role: .destructive) {
                guard let currentItem else { return }
                Task { if await model.delete(id: currentItem.id) { dismiss() } }
            }
            .accessibilityIdentifier("skill-delete-confirm")
            Button("取消", role: .cancel) { }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        let runCount = deletionSummary?.activeRunIDs.count ?? 0
        let runDescription = runCount == 0 ? "没有正在使用它的运行。" : "将停止 \(runCount) 个正在使用它的运行。"
        guard let names = deletionSummary?.skillNames, !names.isEmpty else { return runDescription }
        return "受影响的技能：\(names.joined(separator: "、")). \(runDescription)"
    }

    private func prepareDelete(_ item: SkillItem) {
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
        let definition = SkillDefinition(
            name: name,
            summary: summary,
            instructions: instructions,
            requiredTools: Self.parseCSV(requiredTools),
            optionalTools: Self.parseCSV(optionalTools),
            requiredMCPServers: Self.parseCSV(requiredMCPServers),
            environmentKeys: Self.parseCSV(environmentKeys),
            triggerTerms: Self.parseCSV(triggerTerms)
        )
        let saved = await model.saveUser(id: currentItem?.id,
                                         expectedRevisionID: expectedRevisionID,
                                         definition: definition)
        if let saved { expectedRevisionID = saved.revisionID }
        if saved != nil, item == nil { dismiss() }
    }

    private static func parseCSV(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
private struct MetadataField: View {
    let title: String
    let hint: String
    @Binding var text: String
    let focus: SettingsInputFocus
    let identifier: String
    var readOnly = false

    var body: some View {
        if readOnly {
            LabeledContent(title, value: text.isEmpty ? "无" : text)
        } else {
            LabeledContent(title) {
                SettingsTextField(text: $text, title: hint, focus: focus, identifier: identifier)
            }
        }
    }
}
