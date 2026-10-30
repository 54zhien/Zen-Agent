import SwiftUI

@MainActor
struct SubagentSettingsView: View {
    @Bindable var model: SubagentSettingsModel
    let onRetryCatalog: () -> Void

    var body: some View {
        Form {
            if model.isLoaded {
                Section {
                    Toggle("启用子代理", isOn: Binding(get: {
                        model.configuration?.enabled ?? false
                    }, set: { enabled in
                        Task { await model.setEnabled(enabled) }
                    }))
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("settings-subagent-enabled")
                } footer: {
                    Text("默认关闭。启用后，Parent 最多运行一个 Child；Child 结束后 Parent 才能继续。")
                }

                Section {
                    if model.isCatalogLoaded {
                        Picker("模型策略", selection: Binding(get: {
                            model.modelSelection
                        }, set: { selection in
                            switch selection {
                            case .followParent:
                                Task { await model.setExplicitModelTarget(nil) }
                            case .explicit(let providerInstanceID, let modelID):
                                Task {
                                    await model.setExplicitModelTarget(DelegationModelTarget(
                                        providerInstanceID: providerInstanceID,
                                        modelID: modelID
                                    ))
                                }
                            case .unavailable:
                                break
                            }
                        })) {
                            Text("跟随 Parent").tag(SubagentModelSelection.followParent)
                            ForEach(model.modelOptions) { option in
                                Text(option.title).tag(SubagentModelSelection.explicit(
                                    option.target.providerInstanceID,
                                    option.target.modelID
                                ))
                            }
                            if model.modelSelection == .unavailable {
                                Text("已保存模型不可用").tag(SubagentModelSelection.unavailable)
                            }
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("settings-subagent-model-policy")

                        if model.modelSelection == .unavailable {
                            Text("已保存的 Provider / Model 当前不可用。设置已保留；恢复该目标或选择其他模型，不会自动改为跟随 Parent。")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings-subagent-model-unavailable")
                        }
                        if model.modelOptions.isEmpty {
                            Text("没有可用的 Provider / Model。请先配置支持文本与流式响应的账户。")
                                .foregroundStyle(.secondary)
                        }
                    } else if let message = model.catalogErrorMessage {
                        Text(message).foregroundStyle(.red)
                        Button("重试读取") { onRetryCatalog() }
                    } else {
                        ProgressView("正在读取 Provider 与模型")
                    }
                } header: {
                    Text("默认模型")
                } footer: {
                    Text("跟随 Parent 使用 Parent Run 已冻结的 Provider / Model。显式模型只影响之后启动的 Parent Run。")
                }

                Section("调用层级") {
                    LabeledContent("最大深度", value: "1")
                    Text("Child 不能继续创建 Child。")
                        .foregroundStyle(.secondary)
                }

                if let status = model.statusMessage {
                    Section { Text(status).accessibilityIdentifier("settings-subagent-save-status") }
                }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("settings-subagent-error") }
                }
            } else if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("重试读取") {
                        Task {
                            await model.load()
                            onRetryCatalog()
                        }
                    }
                }
            } else {
                ProgressView("正在读取子代理设置")
            }
        }
        .navigationTitle("子代理")
        .settingsCloseToolbar()
        .task { await model.load() }
    }
}
