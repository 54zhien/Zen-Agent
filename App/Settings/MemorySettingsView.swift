import SwiftUI

@MainActor
struct MemorySettingsView: View {
    let model: MemorySettingsModel
    let focus: SettingsInputFocus
    @State private var confirmClear = false

    var body: some View {
        Form {
            if model.isLoaded {
                Section {
                    Toggle("启用记忆", isOn: Binding(get: { model.settings.enabled }, set: { enabled in
                        Task { await model.setEnabled(enabled) }
                    })).accessibilityIdentifier("memory-enabled")
                    if MemoryRuntime.automaticFormationAvailable {
                        Toggle("自动形成记忆", isOn: Binding(get: { model.settings.automaticEnabled }, set: { enabled in
                            Task { await model.setAutomatic(enabled) }
                        })).disabled(!model.settings.enabled).accessibilityIdentifier("memory-automatic")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("关闭记忆后，新提问不再检索或形成记忆，已有记录仍保留。正在进行的回复保留已选版本。记忆不能授予工具权限。")
                        Text("自动形成记忆仅识别部分明确的长期偏好、开发环境、姓名和主要项目；不支持的表达会跳过。")
                    }
                }
                Section("最近更新的记忆") {
                    if model.items.isEmpty { Text("暂无已保存的记忆").foregroundStyle(.secondary).accessibilityIdentifier("memory-empty") }
                    ForEach(model.items) { item in
                        NavigationLink {
                            MemoryDetailView(model: model, item: item, focus: focus)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.content).lineLimit(3)
                                Text(item.archived ? "已归档" : item.origin.title).foregroundStyle(.secondary)
                                Text(item.updatedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("memory-item-\(item.id)")
                    }
                }
                Section {
                    Button("清空全部记忆", role: .destructive) { confirmClear = true }
                        .disabled(model.items.isEmpty).accessibilityIdentifier("memory-clear")
                } footer: {
                    Text("删除会使依赖这些记忆的后续请求失效；已经发给 Provider 的内容无法撤回。系统历史备份由系统管理。")
                }
            } else { ProgressView("正在读取记忆") }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }
        .disabled(model.isBusy)
        .navigationTitle("记忆").settingsCloseToolbar()
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("刷新") { Task { await model.load() } }.disabled(model.isBusy) } }
        .confirmationDialog("清空全部记忆？此操作无法撤销。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("确认清空全部记忆", role: .destructive) { Task { await model.clear() } }
            Button("取消", role: .cancel) { }
        }
        .task { await model.load() }
    }
}

@MainActor
private struct MemoryDetailView: View {
    let model: MemorySettingsModel
    let focus: SettingsInputFocus
    @State private var item: MemoryItem
    @State private var content: String
    @State private var saved = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(model: MemorySettingsModel, item: MemoryItem, focus: SettingsInputFocus) {
        self.model = model; self.focus = focus
        _item = State(initialValue: item); _content = State(initialValue: item.content)
    }

    var body: some View {
        Form {
            Section("记忆内容") {
                SettingsInstructionsInput(text: $content, focus: focus, accessibilityLabel: "记忆内容", accessibilityIdentifier: "memory-content")
                    .frame(minHeight: 180)
                Text("\(content.utf8.count) / \(MemoryContentPolicy.maximumUTF8Bytes) 字节").foregroundStyle(.secondary)
                if saved { Text("已保存。之后的新提问会使用更新后的记忆；正在进行的回复保持原版本。").accessibilityIdentifier("memory-save-status") }
            }
            Section("来源") {
                Text(item.origin.title)
                if item.sources.isEmpty { Text("由用户手动保存").foregroundStyle(.secondary) }
                ForEach(item.sources) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.kind.title)
                        Text(source.missing ? "来源会话已删除" : "来源会话：\(source.conversationTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名会话")")
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                LabeledContent("创建时间") { Text(item.createdAt, format: .dateTime) }
                LabeledContent("更新时间") { Text(item.updatedAt, format: .dateTime) }
            }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("删除这条记忆", role: .destructive) { confirmDelete = true }.accessibilityIdentifier("memory-delete")
            }
        }
        .disabled(model.isBusy)
        .navigationTitle("记忆详情").settingsCloseToolbar()
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("保存") {
                Task { if let updated = await model.save(item, content: content) { item = updated; saved = true } }
            }.disabled(model.isBusy || focus.hasMarkedText).accessibilityIdentifier("memory-save")
        } }
        .confirmationDialog("删除这条记忆？此操作无法撤销。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认删除记忆", role: .destructive) { Task { if await model.delete(item) { dismiss() } } }
            Button("取消", role: .cancel) { }
        }
        .onChange(of: content) { _, _ in saved = false }
    }
}
