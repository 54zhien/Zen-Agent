import SwiftUI

@MainActor
struct ConversationPreviewView: View {
    let summary: ConversationSummary?
    var status: ConversationPreviewStatus = .ready
    var isNewEntry = false
    var onRefreshFrozenCredential: (@MainActor (String, SecretValue) async throws -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isCredentialRefreshPresented = false
    @State private var credentialRefreshKey = ""
    @State private var credentialRefreshError: String?
    @State private var isRefreshingCredential = false

    private var authenticationRunID: String? {
        guard let projection = summary?.runProjection,
              projection.state == .suspended,
              projection.suspendReason == .authRequired else { return nil }
        return projection.runID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isNewEntry {
                Image(systemName: "plus").font(.largeTitle).accessibilityHidden(true)
            }
            Text(isNewEntry ? "新对话" : (summary?.title ?? "未发送的会话"))
                .font(Typography.font(for: .interfaceTitle, dynamicTypeSize: dynamicTypeSize))
                .lineLimit(2)
            if !isNewEntry, let summary {
                Text(summary.excerpt)
                    .font(Typography.font(for: .conversationBody, dynamicTypeSize: dynamicTypeSize))
                    .lineLimit(8)
                if let runStatus = ConversationCardStatus.derive(from: summary.runProjection) {
                    if authenticationRunID != nil, onRefreshFrozenCredential != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(runStatus.label)
                                .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                                .foregroundStyle(.secondary)
                            Button("更新原账号凭据") { isCredentialRefreshPresented = true }
                                .accessibilityIdentifier("conversation-auth-refresh")
                        }
                    } else {
                        Text(runStatus.label)
                            .font(Typography.font(for: .interfaceCaption, dynamicTypeSize: dynamicTypeSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            switch status {
            case .restoring: ProgressView("正在打开会话")
            case .contentUnavailable: Text("部分内容暂不可用")
            case .failed(let message): Text(message)
            case .ready, .migrationRequired: EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $isCredentialRefreshPresented, onDismiss: {
            credentialRefreshKey = ""
            credentialRefreshError = nil
        }) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("新的 API Key", text: $credentialRefreshKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("conversation-auth-refresh-key")
                    } header: {
                        Text("原账号凭据")
                    } footer: {
                        Text("此操作只更新暂停运行冻结的原账号凭据，不会更改 Provider 当前绑定。")
                    }
                    if let credentialRefreshError {
                        Section { Text(credentialRefreshError).foregroundStyle(.red) }
                    }
                    Section {
                        Button(isRefreshingCredential ? "正在更新…" : "更新并恢复") {
                            refreshFrozenCredential()
                        }
                        .accessibilityIdentifier("conversation-auth-refresh-submit")
                        .disabled(isRefreshingCredential || credentialRefreshKey
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationTitle("更新原账号凭据")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isCredentialRefreshPresented = false }
                            .disabled(isRefreshingCredential)
                    }
                }
            }
        }
    }

    private func refreshFrozenCredential() {
        guard let runID = authenticationRunID,
              let onRefreshFrozenCredential,
              !isRefreshingCredential,
              !credentialRefreshKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let secret = SecretValue(credentialRefreshKey)
        isRefreshingCredential = true
        credentialRefreshError = nil
        Task { @MainActor in
            do {
                try await onRefreshFrozenCredential(runID, secret)
                isCredentialRefreshPresented = false
            } catch {
                credentialRefreshError = "凭据更新或运行恢复未完成，请检查 API Key 后重试。"
            }
            isRefreshingCredential = false
        }
    }
}

extension ConversationCardStatus {
    var label: String {
        switch self {
        case .generating: "生成中"
        case .reasoningVisible: "思考中"
        case .tool: "工具运行中"
        case .approval: "等待批准"
        case .cancelled: "已取消"
        case .failed: "运行失败"
        case .authenticationRequired: "需要重新验证凭据"
        }
    }
}
