import SwiftUI

@MainActor
struct SettingsAccountsView: View {
    let model: SettingsWorkspaceModel
    let focus: SettingsInputFocus
    let onAdd: () -> Void
    var body: some View {
        Form {
            Section {
                ForEach(model.catalog) { entry in
                    NavigationLink {
                        SettingsAccountView(model: model.accountEditor(for: entry.instance), focus: focus,
                            onSaved: { Task { await model.load() } })
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.instance.displayName)
                            Text("\(entry.instance.providerID.displayName) · \(entry.instance.baseURL?.host ?? "Provider 默认地址")")
                                .foregroundStyle(.secondary)
                            Text(entry.credentialStatus).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("添加 Provider") { onAdd() }.accessibilityIdentifier("settings-provider-add")
            } footer: { Text("凭据保存在 Keychain。资料保存与重认证不改变正在运行的请求。") }
            if let error = model.configurationErrorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
            if let status = model.configurationStatusMessage { Section { Text(status) } }
        }.navigationTitle("Providers 与账户").settingsCloseToolbar()
    }
}

@MainActor
private struct SettingsAccountView: View {
    @State var model: ProviderAccountSettingsModel
    let focus: SettingsInputFocus
    let onSaved: () -> Void
    var body: some View {
        Form {
            Section("账户资料") {
                SettingsTextField(text: $model.displayName, title: "账户名称", focus: focus)
                SettingsTextField(text: $model.endpoint, title: "HTTPS 地址（留空使用默认）", focus: focus)
                if model.instance.providerID == .anthropic {
                    SettingsTextField(
                        text: $model.anthropicWorkspaceID,
                        title: "Workspace ID（可选）",
                        focus: focus
                    )
                    Text("已限定 Workspace 的 API Key 可留空；未限定的 API Key 需要填写 Workspace ID。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("保存资料") { Task { await model.saveConfiguration(); onSaved() } }
                    .disabled(model.isBusy || focus.hasMarkedText)
            }
            Section {
                SettingsTextField(text: $model.apiKey, title: "新的 API Key", focus: focus, secure: true)
                Button("保存新凭据") { Task { await model.reauthenticate(); onSaved() } }
                    .disabled(model.isBusy || focus.hasMarkedText)
            } header: { Text("重认证") } footer: {
                Text("此操作只更新凭据绑定，不保存上方资料草稿。已有请求保留原凭据引用。保存成功不代表已联网验证。")
            }
            if let status = model.statusMessage { Section { Text(status) } }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("账户").settingsCloseToolbar()
    }
}

@MainActor
struct SettingsModelsView: View {
    let model: SettingsWorkspaceModel
    var body: some View {
        List {
            Section { Text("全局默认用于后续新会话。当前会话的模型仍在 Composer 中选择。") }
            Section("图像输入模型") {
                Text("图像输入使用独立模型槽位，不会更改全局默认或当前会话模型。当前发送流程尚未接入此槽位。")
                    .foregroundStyle(.secondary)
                if let target = model.imageInputTarget {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("账号：\(model.imageInputAccountName ?? "账号已删除或不可用")")
                        Text("Provider：\(model.imageInputProviderName ?? target.providerInstanceID.rawValue)")
                        Text("模型：\(model.imageInputModelName ?? target.modelID.rawValue)")
                        Text("Endpoint：\(model.imageInputEndpointDisplay ?? "实际 endpoint 暂不可解析")")
                            .textSelection(.enabled)
                        Text(model.imageInputAvailabilityMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-image-input-status")
                    }
                    Button("清除图像输入模型", role: .destructive) {
                        model.clearImageInputModel()
                    }
                    .accessibilityIdentifier("settings-image-input-clear")
                } else {
                    Text(model.imageInputAvailabilityMessage)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-image-input-status")
                }
                if let error = model.imageInputSelectionErrorMessage {
                    Text(error).foregroundStyle(.red)
                }

                let candidateCount = model.catalog.reduce(0) {
                    $0 + model.imageInputModels(in: $1).count
                }
                if let status = model.imageInputCatalogStatusMessage {
                    Text(status).foregroundStyle(.secondary)
                    if model.canRetryImageInputCatalog {
                        Button("重试读取") { Task { await model.load() } }
                            .disabled(model.isLoading)
                    }
                } else if candidateCount == 0 {
                    Text("当前没有模型声明图像输入能力。请在 Providers 与账户中添加或修改支持图像的 Provider。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.catalog) { entry in
                        let imageModels = model.imageInputModels(in: entry)
                        if !imageModels.isEmpty {
                            ForEach(imageModels) { descriptor in
                                let selected = model.imageInputTarget == AppExecutionTarget(
                                    providerInstanceID: entry.id, modelID: descriptor.id)
                                let endpoint = model.requestEndpointDisplay(providerInstanceID: entry.id,
                                    modelID: descriptor.id) ?? "实际 endpoint 暂不可解析"
                                Button {
                                    Task {
                                        _ = await model.setImageInputModel(providerInstanceID: entry.id,
                                            modelID: descriptor.id)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(selected ? "图像输入模型 · \(descriptor.displayName)" : descriptor.displayName)
                                            Spacer()
                                            if selected { Image(systemName: "checkmark") }
                                        }
                                        Text("\(entry.instance.displayName) · \(entry.instance.providerID.displayName)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                        Text("Endpoint：\(endpoint)")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                        Text(entry.credentialStatus)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isSelectingImageInputModel)
                                .accessibilityIdentifier("settings-image-input-candidate-\(entry.id.rawValue)-\(descriptor.id.rawValue)")
                            }
                        }
                    }
                }
            }
            ForEach(model.catalog) { entry in
                let ordered = model.menus.orderedModels(entry.models)
                Section(entry.instance.displayName) {
                    ForEach(ordered) { descriptor in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(descriptor.displayName)
                            Text(capabilitySummary(descriptor)).foregroundStyle(.secondary)
                            if model.isConfigureMode {
                                Button("用于当前会话") { Task {
                                    _ = await model.configureCapturedConversation(providerInstanceID: entry.id, modelID: descriptor.id)
                                }}.disabled(model.isConfiguringConversation).buttonStyle(.borderless)
                            }
                            Toggle("在模型菜单中显示", isOn: Binding(get: {
                                !model.menus.isHidden(descriptor.id, in: entry.id)
                            }, set: { visible in
                                model.menus.setHidden(!visible, modelID: descriptor.id, instanceID: entry.id)
                            }))
                            if model.defaultTarget == AppExecutionTarget(providerInstanceID: entry.id, modelID: descriptor.id) {
                                Text("全局默认").foregroundStyle(.secondary)
                            } else {
                                Button("设为全局默认") { Task {
                                    _ = await model.setDefault(providerInstanceID: entry.id, modelID: descriptor.id)
                                }}.disabled(model.isSelectingDefault).buttonStyle(.borderless)
                            }
                        }
                    }.onMove { source, destination in
                        var models = ordered
                        models.move(fromOffsets: source, toOffset: destination)
                        model.menus.setOrder(models.map(\.id), for: entry.id)
                    }
                }
            }
            if let status = model.configurationStatusMessage {
                Section { Text(status).accessibilityIdentifier("settings-conversation-configuration-status") }
            }
            if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("模型").settingsCloseToolbar().toolbar { EditButton() }
    }

    private func capabilitySummary(_ descriptor: ModelDescriptor) -> String {
        let names: [(ModelCapability, String)] = [(.text, "文本"), (.streaming, "流式"),
            (.reasoning, "推理"), (.vision, "图像"), (.files, "文件"), (.tools, "工具")]
        return names.filter { descriptor.capabilities.contains($0.0) }.map(\.1).joined(separator: " · ")
    }
}
