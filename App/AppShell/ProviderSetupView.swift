import Foundation
import Observation
import SwiftUI

enum ProviderSetupState: Equatable {
    case idle
    case saving
    case incomplete
    case identifierConflict
    case complete
}

enum ProviderSetupFailure: Error, Equatable {
    case keyMissing
    case keychainUnavailable
    case credentialFailed
    case credentialReadFailed
    case credentialStorageUnavailable
    case credentialStorageFailed
    case authenticationRequired
    case bindingMoved
    case instanceConflict
    case instanceChanged
    case editConflict
    case modelUnavailable
    case keyRequired
    case persistenceUnavailable

    var message: String {
        switch self {
        case .keyMissing:
            return "Key 缺失"
        case .keychainUnavailable:
            return "Keychain 不可用"
        case .credentialFailed:
            return "凭据存储异常"
        case .credentialReadFailed:
            return "凭据读取失败，请稍后重试"
        case .credentialStorageUnavailable:
            return "Keychain 暂不可用，请稍后重试"
        case .credentialStorageFailed:
            return "凭据存储失败"
        case .authenticationRequired:
            return "凭据需要重新配置"
        case .bindingMoved:
            return "凭据配置已变化，请重新验证"
        case .instanceConflict:
            return "实例 ID 冲突，无法安全续接。"
        case .instanceChanged:
            return "实例资料已变化，无法安全续接。"
        case .editConflict:
            return "实例在保存期间发生变化，请检查后重试。"
        case .modelUnavailable:
            return "所选模型不可用，配置尚未完成。"
        case .keyRequired:
            return "请输入 API Key"
        case .persistenceUnavailable:
            return "保存配置失败，请重试。"
        }
    }
}

@MainActor
@Observable
final class ProviderSetupModel {
    private(set) var instanceID: ProviderInstanceID
    private(set) var credentialReference: CredentialReference
    private(set) var didCreateInstance = false
    private(set) var didAttachCredential = false
    var selectedModelID: ModelID?
    var apiKey = ""
    private(set) var state: ProviderSetupState = .idle
    private(set) var errorMessage: String?
    private(set) var canAbandonAndCreateNew = false

    @ObservationIgnored private let store: PersistenceStore
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let provider: any ModelProvider
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let onTargetSaved: @MainActor (AppExecutionTarget) -> Void
    @ObservationIgnored private let afterAttachSnapshot: (@MainActor (ProviderInstance) -> Void)?

    var isSaving: Bool { state == .saving }
    var isComplete: Bool { state == .complete }
    var isIdentifierConflict: Bool { state == .identifierConflict }

    var statusLabel: String {
        switch state {
        case .idle:
            return "尚未保存"
        case .saving:
            return "正在保存"
        case .incomplete:
            return "未完成配置"
        case .identifierConflict:
            return "实例 ID 冲突"
        case .complete:
            return "配置完成"
        }
    }

    var models: [ModelDescriptor] {
        provider.knownModels(for: draftInstance(credentialReference: nil))
    }

    init(
        store: PersistenceStore,
        credentials: any CredentialStoring,
        provider: any ModelProvider,
        userDefaults: UserDefaults,
        instanceID: ProviderInstanceID = ProviderInstanceID(rawValue: UUID().uuidString),
        credentialReference: CredentialReference = CredentialReference(
            id: UUID().uuidString,
            kind: .apiKey
        ),
        afterAttachSnapshot: (@MainActor (ProviderInstance) -> Void)? = nil,
        onTargetSaved: @escaping @MainActor (AppExecutionTarget) -> Void = { _ in }
    ) {
        self.store = store
        self.credentials = credentials
        self.provider = provider
        self.userDefaults = userDefaults
        self.instanceID = instanceID
        self.credentialReference = credentialReference
        self.afterAttachSnapshot = afterAttachSnapshot
        self.onTargetSaved = onTargetSaved
        self.selectedModelID = provider.knownModels(for: ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: nil,
            configRevision: .initial,
            credentialReference: nil
        )).first?.id
    }

    @discardableResult
    func save() -> Bool {
        guard state != .saving, state != .complete else { return state == .complete }
        let submittedKey = apiKey
        apiKey = ""
        errorMessage = nil
        canAbandonAndCreateNew = false
        state = .saving

        do {
            var instance = try ensureInstance()
            try ensureCredential(using: submittedKey)

            if !didAttachCredential || instance.credentialReference != credentialReference {
                guard let latest = try store.providerInstance(id: instanceID) else {
                    throw ProviderSetupFailure.instanceChanged
                }
                instance = latest
                afterAttachSnapshot?(instance)
                instance = try store.attachCredential(
                    credentialReference,
                    toInstance: instanceID,
                    expectedEditRevision: instance.editRevision
                )
                didAttachCredential = true
            }

            guard let modelID = selectedModelID,
                  let descriptor = provider.knownModels(for: instance).first(where: {
                      $0.id == modelID && $0.providerInstanceID == instance.id
                  }),
                  descriptor.capabilities.contains(.text),
                  descriptor.capabilities.contains(.streaming) else {
                throw ProviderSetupFailure.modelUnavailable
            }
            _ = try AppAssembly.validateTarget(
                providerInstanceID: instanceID,
                modelID: modelID,
                store: store,
                provider: provider,
                credentials: credentials
            )

            let target = AppExecutionTarget(providerInstanceID: instanceID, modelID: modelID)
            userDefaults.set(instanceID.rawValue, forKey: AppShellModel.defaultInstanceIDKey)
            userDefaults.set(modelID.rawValue, forKey: AppShellModel.defaultModelIDKey)
            state = .complete
            onTargetSaved(target)
            return true
        } catch {
            state = Self.isIdentifierConflict(error) ? .identifierConflict : .incomplete
            errorMessage = Self.safeMessage(for: error)
            canAbandonAndCreateNew = Self.isIdentifierConflict(error)
                || (error as? ProviderSetupFailure) == .instanceChanged
            return false
        }
    }

    func startNewAttempt() {
        instanceID = ProviderInstanceID(rawValue: UUID().uuidString)
        credentialReference = CredentialReference(id: UUID().uuidString, kind: .apiKey)
        didCreateInstance = false
        didAttachCredential = false
        selectedModelID = models.first?.id
        apiKey = ""
        state = .idle
        errorMessage = nil
        canAbandonAndCreateNew = false
    }

    private func ensureInstance() throws -> ProviderInstance {
        if let existing = try store.providerInstance(id: instanceID) {
            guard didCreateInstance else { throw ProviderSetupFailure.instanceConflict }
            guard existing.providerID == .deepSeek,
                  existing.credentialReference == nil
                    || existing.credentialReference == credentialReference else {
                throw ProviderSetupFailure.instanceChanged
            }
            return existing
        }

        let instance = draftInstance(credentialReference: nil)
        do {
            try store.createProviderInstance(instance)
            didCreateInstance = true
        } catch let error as PersistenceError {
            if case .providerInstanceAlreadyExists = error {
                throw ProviderSetupFailure.instanceConflict
            }
            throw error
        }
        guard let created = try store.providerInstance(id: instanceID) else {
            throw ProviderSetupFailure.persistenceUnavailable
        }
        return created
    }

    private func ensureCredential(using key: String) throws {
        let metadata: CredentialMetadata?
        do {
            metadata = try credentials.metadata(for: credentialReference)
        } catch {
            throw ProviderSetupFailure.credentialFailed
        }

        if let metadata {
            let resolved: SecretValue?
            do {
                resolved = try credentials.resolve(
                    frozenReference: metadata.reference,
                    generation: metadata.bindingGeneration
                )
            } catch {
                throw Self.failure(for: error)
            }
            if resolved != nil { return }
            try credentials.refresh(
                Self.secret(from: key),
                for: credentialReference,
                at: Date()
            )
            return
        }

        try credentials.provision(
            Self.secret(from: key),
            as: credentialReference,
            principalFingerprint: nil,
            at: Date()
        )
    }

    private func draftInstance(credentialReference: CredentialReference?) -> ProviderInstance {
        ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "DeepSeek",
            baseURL: nil,
            configRevision: .initial,
            editRevision: .initial,
            credentialReference: credentialReference
        )
    }

    private static func secret(from key: String) throws -> SecretValue {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderSetupFailure.keyRequired
        }
        return SecretValue(key)
    }

    private static func failure(for error: Error) -> ProviderSetupFailure {
        guard let error = error as? CredentialError else { return .credentialFailed }
        switch error {
        case .unavailable:
            return .keychainUnavailable
        case .failed:
            return .credentialReadFailed
        case .authenticationRequired:
            return .authenticationRequired
        case .bindingMoved:
            return .bindingMoved
        case .alreadyExists, .notFound:
            return .keyMissing
        }
    }

    private static func isIdentifierConflict(_ error: Error) -> Bool {
        if let failure = error as? ProviderSetupFailure, failure == .instanceConflict {
            return true
        }
        if let persistence = error as? PersistenceError,
           case .providerInstanceAlreadyExists = persistence {
            return true
        }
        return false
    }

    private static func safeMessage(for error: Error) -> String {
        if let failure = error as? ProviderSetupFailure { return failure.message }
        if let failure = error as? AppTargetFailure { return failure.message }
        if let failure = error as? SecretBackendError {
            switch failure {
            case .unavailable:
                return ProviderSetupFailure.credentialStorageUnavailable.message
            case .failed:
                return ProviderSetupFailure.credentialStorageFailed.message
            }
        }
        if let persistence = error as? PersistenceError,
           case .providerInstanceEditConflict = persistence {
            return ProviderSetupFailure.editConflict.message
        }
        if let credential = error as? CredentialError { return failure(for: credential).message }
        return ProviderSetupFailure.persistenceUnavailable.message
    }
}

@MainActor
struct ProviderSetupView: View {
    @Bindable var model: ProviderSetupModel
    let retryExistingTarget: @MainActor () -> String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @State private var retryMessage: String?

    init(
        model: ProviderSetupModel,
        retryExistingTarget: @escaping @MainActor () -> String = { "" }
    ) {
        self.model = model
        self.retryExistingTarget = retryExistingTarget
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    LabeledContent("Provider", value: "DeepSeek")
                }

                Section("实例与模型") {
                    LabeledContent("新建实例", value: "DeepSeek")
                    Picker("模型", selection: $model.selectedModelID) {
                        Text("选择模型").tag(nil as ModelID?)
                        ForEach(model.models) { descriptor in
                            Text(descriptor.displayName).tag(Optional(descriptor.id))
                        }
                    }
                }

                Section("API Key") {
                    SecureField("DeepSeek API Key", text: $model.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("保存状态") {
                    Text(model.statusLabel)
                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("provider-setup-error")
                    }
                    Button(model.isComplete ? "配置完成" : "保存配置") {
                        _ = model.save()
                    }
                    .disabled(model.isSaving || model.isComplete || model.models.isEmpty)
                    if model.isComplete {
                        Button("重新配置（新实例）") {
                            model.startNewAttempt()
                        }
                    }
                    Button("重试验证现有配置") {
                        retryMessage = retryExistingTarget()
                    }
                    .disabled(model.isSaving)
                    if let retryMessage, !retryMessage.isEmpty {
                        Text(retryMessage)
                            .foregroundStyle(retryMessage == "配置已恢复" ? Color.secondary : Color.red)
                            .accessibilityIdentifier("provider-setup-target-retry")
                    }
                    if model.canAbandonAndCreateNew {
                        Button("放弃本次并新建", role: .destructive) {
                            model.startNewAttempt()
                        }
                    }
                }
            }
            .font(Typography.font(for: .interfaceBody, dynamicTypeSize: dynamicTypeSize))
            .navigationTitle("配置模型")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
