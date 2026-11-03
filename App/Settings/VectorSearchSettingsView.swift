import SwiftUI

@MainActor
struct VectorSearchSettingsView: View {
    @Bindable var model: VectorSearchSettingsModel

    var body: some View {
        Form {
            if model.isLoaded {
                Section("OpenAI 账户") {
                    if model.accounts.isEmpty {
                        Text("请先在 Providers 与账户中添加 OpenAI 账户。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("用于语义搜索", selection: selection) {
                            Text("未选择").tag("")
                            ForEach(model.accounts) { account in
                                Text(account.title).tag(account.id.rawValue)
                            }
                        }
                        .accessibilityIdentifier("semantic-search-account")
                    }
                    Text("这里只使用已有 OpenAI 账户的凭据，不会保存新的 API Key。")
                        .foregroundStyle(.secondary)
                }
                Section("数据发送") {
                    Text("只有提交语义搜索后，当前可见会话中已完成的用户与助手正文，以及查询词，才会发送到所选 OpenAI 账户。")
                    Text("生成的向量保存在本机的可重建索引中，不参与系统备份。原始会话正文保留在会话数据库中。")
                }
                if let message = model.statusMessage {
                    Section { Text(message) }
                }
            } else if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("重试读取") { Task { await model.load() } }
                }
            } else {
                ProgressView("正在读取 OpenAI 账户")
            }
            if model.isLoading { ProgressView() }
        }
        .navigationTitle("语义搜索")
        .settingsCloseToolbar()
        .task { await model.load() }
    }

    private var selection: Binding<String> {
        Binding(
            get: { model.selectedProviderInstanceID?.rawValue ?? "" },
            set: { rawValue in
                model.selectAccount(rawValue.isEmpty ? nil : ProviderInstanceID(rawValue: rawValue))
            }
        )
    }
}
