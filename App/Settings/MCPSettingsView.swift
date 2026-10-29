import SwiftUI

@MainActor
struct MCPSettingsView: View {
    let model: MCPSettingsModel
    let toolSettings: ToolSettingsModel
    let focus: SettingsInputFocus
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                Text("已连接的 MCP 服务会提供工具、资源和提示。工具仍通过统一的工具策略检查。")
                    .foregroundStyle(.secondary)
            }
            if model.isLoaded {
                Section("MCP 服务") {
                    if model.servers.isEmpty {
                        Text("暂无 MCP 服务").foregroundStyle(.secondary)
                            .accessibilityIdentifier("mcp-empty")
                    }
                    ForEach(model.servers, id: \.id) { server in
                        HStack(spacing: 12) {
                            NavigationLink {
                                MCPServerDetailView(model: model, toolSettings: toolSettings,
                                                    server: server, focus: focus)
                            } label: {
                                MCPServerListLabel(server: server, snapshot: model.snapshot(for: server))
                            }
                            .accessibilityIdentifier("mcp-server-\(server.id)")
                            Toggle("启用 \(server.displayName)", isOn: Binding(
                                get: { server.enabled },
                                set: { enabled in Task { await model.setEnabled(serverID: server.id, enabled: enabled) } }
                            ))
                            .labelsHidden()
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("mcp-enabled-\(server.id)")
                        }
                    }
                }
            } else if model.errorMessage == nil {
                Section { ProgressView("正在读取 MCP 服务") }
            }
            if let status = model.statusMessage {
                Section { Text(status).foregroundStyle(.secondary).accessibilityIdentifier("mcp-status") }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("重试读取") { Task { await model.load() } }
                        .accessibilityIdentifier("mcp-retry")
                }
            }
        }
        .navigationTitle("MCP")
        .settingsCloseToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { Task { await model.load() } }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("mcp-refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加") { isAdding = true }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("mcp-add")
            }
        }
        .navigationDestination(isPresented: $isAdding) {
            MCPServerDetailView(model: model, toolSettings: toolSettings, server: nil, focus: focus)
        }
        .task { await model.load() }
    }
}

@MainActor
private struct MCPServerListLabel: View {
    let server: MCPServer
    let snapshot: MCPServerConnectionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(server.displayName).foregroundStyle(.primary)
            Text(stateTitle(snapshot.state))
                .font(.subheadline).foregroundStyle(stateColor(snapshot.state))
            Text(snapshot.capabilitySummary)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func stateTitle(_ state: MCPServerConnectionState) -> String {
        switch state {
        case .disabled: "已停用"
        case .disconnected: "未连接"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .authenticationRequired: "需要凭据"
        case .failed: "连接失败"
        }
    }

    private func stateColor(_ state: MCPServerConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .failed, .authenticationRequired: .orange
        default: .secondary
        }
    }
}

@MainActor
private struct MCPServerDetailView: View {
    let model: MCPSettingsModel
    let toolSettings: ToolSettingsModel
    let server: MCPServer?
    let focus: SettingsInputFocus
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var endpoint: String
    @State private var authenticationOptionID: String
    @State private var isConfirmingDelete = false

    init(model: MCPSettingsModel, toolSettings: ToolSettingsModel, server: MCPServer?,
         focus: SettingsInputFocus) {
        self.model = model
        self.toolSettings = toolSettings
        self.server = server
        self.focus = focus
        _displayName = State(initialValue: server?.displayName ?? "")
        _endpoint = State(initialValue: server?.endpoint ?? "")
        _authenticationOptionID = State(initialValue: model.authenticationOptionID(for: server?.authenticationReference))
    }

    private var currentServer: MCPServer? {
        guard let server else { return nil }
        return model.servers.first(where: { $0.id == server.id }) ?? server
    }

    private var snapshot: MCPServerConnectionSnapshot? {
        currentServer.map { model.snapshot(for: $0) }
    }

    var body: some View {
        Form {
            Section("服务配置") {
                SettingsTextField(text: $displayName, title: "服务名称", focus: focus,
                                  identifier: "mcp-name")
                SettingsTextField(text: $endpoint, title: "https://服务器地址", focus: focus,
                                  identifier: "mcp-endpoint")
                Text("默认使用 HTTPS。只有手动配置受信任的局域网服务时才使用 HTTP。")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Bearer 凭据", selection: $authenticationOptionID) {
                    Text("不使用凭据").tag("")
                    ForEach(model.authenticationOptions(for: currentServer?.authenticationReference)) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .accessibilityIdentifier("mcp-credential-reference")
                Text("所选引用会作为 Bearer 凭据发送到此地址；密钥内容不会显示。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mcp-credential-note")
            }
            if let currentServer {
                Section("连接") {
                    LabeledContent("状态", value: stateTitle(snapshot?.state ?? currentServer.connectionState))
                    if let info = snapshot?.serverInfo {
                        LabeledContent("服务器", value: "\(info.name) · \(info.version)")
                    }
                    Toggle("启用服务", isOn: Binding(
                        get: { currentServer.enabled },
                        set: { enabled in Task { await model.setEnabled(serverID: currentServer.id, enabled: enabled) } }
                    ))
                    .disabled(model.isBusy)
                    if currentServer.enabled {
                        if snapshot?.state == .connected {
                            Button("断开连接") { Task { await model.disconnect(serverID: currentServer.id) } }
                                .disabled(model.isBusy)
                                .accessibilityIdentifier("mcp-disconnect")
                            Button("重新连接") { Task { await model.reconnect(serverID: currentServer.id) } }
                                .disabled(model.isBusy)
                                .accessibilityIdentifier("mcp-reconnect")
                        } else {
                            Button(connectionActionTitle) {
                                Task { await model.connect(serverID: currentServer.id) }
                            }
                            .disabled(model.isBusy || snapshot?.state == .connecting)
                            .accessibilityIdentifier("mcp-connect")
                        }
                    }
                    if let lastError = snapshot?.lastError, !lastError.isEmpty {
                        Text(lastError).foregroundStyle(.red)
                            .accessibilityIdentifier("mcp-last-error")
                    }
                }
                Section {
                    Text(snapshot?.state == .connected ? "当前服务已公布的能力。" : "连接后会读取服务器能力。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("能力")
                }
                capabilitySection("Tools", empty: "暂无工具", items: snapshot?.tools ?? []) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.title ?? tool.name)
                        if let description = tool.description, !description.isEmpty {
                            Text(description).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                capabilitySection("Resources", empty: "暂无资源", items: snapshot?.resources ?? []) { resource in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resource.title ?? resource.name)
                        Text(resource.uri).font(.footnote).foregroundStyle(.secondary)
                        if let description = resource.description, !description.isEmpty {
                            Text(description).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                capabilitySection("Prompts", empty: "暂无提示", items: snapshot?.prompts ?? []) { prompt in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prompt.title ?? prompt.name)
                        if let description = prompt.description, !description.isEmpty {
                            Text(description).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("工具策略") {
                    NavigationLink {
                        ToolSettingsView(model: toolSettings)
                    } label: {
                        Label("查看统一工具策略", systemImage: "checkmark.shield")
                    }
                    .accessibilityIdentifier("mcp-tool-policy")
                }
                Section {
                    Button("删除 MCP 服务", role: .destructive) { isConfirmingDelete = true }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("mcp-delete")
                }
            }
            if let status = model.statusMessage {
                Section { Text(status).foregroundStyle(.secondary).accessibilityIdentifier("mcp-detail-status") }
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("mcp-detail-error") }
            }
        }
        .navigationTitle(server == nil ? "添加 MCP 服务" : "MCP 服务")
        .settingsCloseToolbar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("mcp-save")
            }
        }
        .confirmationDialog("删除此 MCP 服务？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await delete() } }
                .accessibilityIdentifier("mcp-delete-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除服务器配置和连接状态。")
        }
    }

    private var connectionActionTitle: String {
        switch snapshot?.state {
        case .connected: "断开连接"
        case .connecting: "正在连接"
        case .failed, .authenticationRequired: "重试连接"
        default: "连接"
        }
    }

    private func stateTitle(_ state: MCPServerConnectionState) -> String {
        switch state {
        case .disabled: "已停用"
        case .disconnected: "未连接"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .authenticationRequired: "需要凭据"
        case .failed: "连接失败"
        }
    }

    private func save() async {
        guard let saved = await model.save(serverID: server?.id, displayName: displayName,
                                           endpoint: endpoint, authenticationOptionID: authenticationOptionID) else { return }
        if server == nil { dismiss() }
        else { displayName = saved.displayName; endpoint = saved.endpoint }
    }

    private func delete() async {
        guard let server, await model.delete(serverID: server.id) else { return }
        dismiss()
    }

    @ViewBuilder
    private func capabilitySection<Item: Identifiable, Content: View>(
        _ title: String, empty: String, items: [Item],
        @ViewBuilder content: (Item) -> Content
    ) -> some View {
        if items.isEmpty {
            LabeledContent(title, value: empty)
        } else {
            Section(title) {
                ForEach(items) { item in content(item) }
            }
        }
    }
}
