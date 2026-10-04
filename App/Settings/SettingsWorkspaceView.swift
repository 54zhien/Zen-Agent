import SwiftUI

@MainActor
struct SettingsWorkspaceView: View {
    let model: SettingsWorkspaceModel
    let onClose: () -> Void
    let onFiles: () -> Void
    @State private var focus = SettingsInputFocus()
    @State private var setupFocus = SettingsInputFocus()
    @State private var setup: ProviderSetupModel?
    @State private var isSetupPresented = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Form {
                Section("模型与服务") {
                    NavigationLink { SettingsAccountsView(model: model, focus: focus, onAdd: addProvider) }
                        label: { Label("Providers 与账户", systemImage: "network") }
                        .accessibilityIdentifier("settings-providers")
                    NavigationLink { SettingsModelsView(model: model) }
                        label: { Label("模型", systemImage: "list.bullet") }
                }
                Section("外观") {
                    NavigationLink { SettingsAppearanceView(model: model.appearance) }
                        label: { Label("外观", systemImage: "circle.lefthalf.filled") }
                }
                Section("Agent") {
                    NavigationLink { SettingsAgentView(model: model.soul, focus: focus) }
                        label: { Label("Agent", systemImage: "sparkle") }
                        .accessibilityIdentifier("settings-agent")
                }
                Section("文件与存储") {
                    Button("文件") { focus.release(then: onFiles) }.disabled(model.storage == nil)
                    NavigationLink { SettingsStorageView(model: model.storage) }
                        label: { Label("存储", systemImage: "internaldrive") }
                }
                Section("数据与隐私") {
                    NavigationLink { SettingsPrivacyView() }
                        label: { Label("本地数据与隐私", systemImage: "lock") }
                }
                Section("关于") {
                    NavigationLink { SettingsAboutView() }
                        label: { Label("关于 Zen", systemImage: "info.circle") }
                }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red); Button("重试读取") { Task { await model.load() } } }
                }
            }
            .navigationTitle("设置")
        }
        .accessibilityIdentifier("settings-page")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { focus.release(then: onClose) }
                    .disabled(isSetupPresented || focus.hasMarkedText || focus.isClosing)
                    .accessibilityIdentifier("settings-close")
            }
        }
        .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
        .preferredColorScheme(model.appearance.appearance.colorScheme)
        .task { await model.load() }
        .sheet(isPresented: $isSetupPresented, onDismiss: {
            setupFocus.cancel(); setup = nil
            Task { await model.load() }
        }) {
            if let setup {
                ProviderSetupView(model: setup, settingsFocus: setupFocus)
                    .interactiveDismissDisabled(true)
            }
        }
        .onDisappear { focus.cancel(); setupFocus.cancel() }
    }

    private func addProvider() {
        focus.release {
            guard let fresh = model.makeProviderSetup() else { return }
            // Close releases the root presentation. A nested creation sheet needs
            // a separate responder owner and leaves the outer presentation active.
            focus = SettingsInputFocus()
            setupFocus = SettingsInputFocus()
            setup = fresh; isSetupPresented = true
        }
    }
}

@MainActor
private struct SettingsAgentView: View {
    let model: SoulSettingsModel
    let focus: SettingsInputFocus
    var body: some View {
        Form {
            NavigationLink { SoulSettingsView(model: model, focus: focus) }
                label: { Text("Soul") }.accessibilityIdentifier("settings-soul")
        }.navigationTitle("Agent")
    }
}

@MainActor
private struct SoulSettingsView: View {
    @Bindable var model: SoulSettingsModel
    let focus: SettingsInputFocus
    var body: some View {
        Form {
            if model.isLoaded {
                Section {
                    if model.hasSoul {
                        Toggle("启用 Soul", isOn: Binding(get: { model.enabled }, set: { value in
                            Task { await model.setEnabled(value) }
                        })).disabled(model.isBusy)
                    } else { Text("首次保存后启用 Soul。") }
                    if let message = model.statusMessage {
                        Text(message).accessibilityIdentifier("settings-soul-save-status")
                    }
                    if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                }
                Section {
                    SettingsInstructionsInput(text: $model.instructions, focus: focus)
                        .frame(minHeight: 180).disabled(model.isBusy)
                } header: { Text("指令") } footer: {
                    Text("保存创建新版本。已有会话保留原绑定；关闭 Soul 会暂停注入，保留版本与绑定。")
                }
            } else {
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("重试读取") { Task { await model.load() } }
                } else { ProgressView("正在读取 Soul") }
            }
        }
        .navigationTitle("Soul")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await model.save() } }
                    .disabled(!model.isLoaded || model.isBusy || focus.hasMarkedText)
                    .accessibilityIdentifier("settings-soul-save")
            }
        }
        .task { await model.load() }
    }
}

@MainActor
private struct SettingsAppearanceView: View {
    @Bindable var model: AppearanceSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Form {
            Section("显示") {
                Picker("外观", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Text(reduceMotion ? "已跟随系统减少动态效果" : "动态效果跟随系统设置")
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("外观")
    }
}
