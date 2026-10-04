import SwiftUI

@MainActor
struct SettingsStorageView: View {
    let model: SettingsStorageModel?
    var body: some View {
        Form {
            if let model {
                if let size = model.footprint {
                    Section("本地记录") {
                        LabeledContent("数据库与 WAL/SHM", value: size.databaseBytes.map(bytes) ?? "内存数据库，未占用数据库文件")
                        LabeledContent("会话记录", value: String(size.conversations))
                        LabeledContent("消息", value: String(size.messages))
                        LabeledContent("请求快照", value: String(size.snapshots))
                        Text("快照包含在数据库内，不重复计入用量。文件长度与记录数量为读取时的估算。")
                            .foregroundStyle(.secondary)
                    }
                    Section("文件") {
                        LabeledContent("托管文件", value: bytes(size.managedBytes))
                        LabeledContent("文件记录", value: String(size.fileAssets))
                        LabeledContent("预览与导出缓存", value: bytes(size.cacheBytes))
                        Text("附件默认进入 Zen Files。文件出现在 Workspace 不等于授予 Agent 读取权限。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("刷新用量") { Task { await model.refresh() } }.disabled(model.isBusy)
                    Button("清理缓存") { Task { await model.clearCache() } }.disabled(model.isBusy)
                } footer: { Text("只清理可重建的临时副本；正在使用的副本、会话草稿和托管文件继续保留。") }
                if model.isBusy { ProgressView() }
                if let status = model.statusMessage { Text(status) }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            } else { Text("文件存储服务当前不可用。") }
        }.navigationTitle("存储").settingsCloseToolbar().task { await model?.refresh() }
    }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct SettingsPrivacyView: View {
    var body: some View {
        Form {
            Section("本地数据") {
                Text("会话、消息、Soul 版本和请求快照保存在应用的本地数据库。托管文件保存在应用数据目录。")
                Text("API Key 保存在 Keychain；数据库只保存凭据引用。设置列表不展示密钥。")
            }
            Section("模型请求") {
                Text("发送请求时，所选 Provider 接收该请求需要的内容。Workspace 文件存在与 Agent 读取权限分别管理。")
            }
            Section("临时副本") {
                Text("预览与导出使用临时副本。清理缓存不会删除会话、Soul 或托管文件。")
            }
        }.navigationTitle("数据与隐私").settingsCloseToolbar()
    }
}

struct SettingsAboutView: View {
    var body: some View {
        Form {
            Section("Zen") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未提供")
                LabeledContent("构建", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未提供")
            }
            Section("许可与致谢") {
                NavigationLink("GRDB") { BundledNoticeView(title: "GRDB", resource: "LICENSE-GRDB-7.11.1") }
                NavigationLink("Source Han Serif") { BundledNoticeView(title: "Source Han Serif", resource: "LICENSE-SourceHanSerif") }
                NavigationLink("JetBrains Mono") { BundledNoticeView(title: "JetBrains Mono", resource: "LICENSE-JetBrainsMono") }
                Text("Anthropic Sans 的应用嵌入与发行许可尚未确认。当前字体清单保留此发行限制。")
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("关于").settingsCloseToolbar()
    }
}

private struct BundledNoticeView: View {
    let title: String
    let resource: String
    var body: some View {
        ScrollView {
            Text(notice).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle(title).settingsCloseToolbar()
    }
    private var notice: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "许可文件未能读取，请检查应用资源。"
        }
        return content
    }
}
