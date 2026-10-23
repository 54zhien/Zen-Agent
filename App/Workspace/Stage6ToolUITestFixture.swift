#if DEBUG
import SwiftUI
import Observation

/// Exercises the production shell, Runtime and persistence with deterministic
/// Provider/OS boundaries. No test capability enters the production registry.
@MainActor
struct Stage6ToolUITestFixture: View {
    @State private var model: AppShellModel
    @State private var observer: Stage6ToolUIObserver
    @State private var opened = false
    private let store: PersistenceStore

    init() {
        do {
            let store = PersistenceStore(database: try ZenDatabase.inMemory())
            self.store = store
            let credentials = CredentialStore(secrets: Stage6UISecrets(), metadataRepository: store)
            let reference = CredentialReference(id: "stage6-ui-key")
            try credentials.provision(SecretValue("stage6-ui-fixture-secret"), as: reference)
            let instance = ProviderInstance(id: .init(rawValue: "stage6-provider"), providerID: .deepSeek,
                displayName: "Stage 6 fixture", baseURL: URL(string: "https://stage6-provider.invalid"),
                configRevision: .initial, credentialReference: reference)
            try store.createProviderInstance(instance)
            try store.createEmptyConversation(id: "stage6-conversation", at: Date(),
                initialBinding: .init(providerInstanceID: instance.id, modelID: .init(rawValue: "fake-model")))
            let files = ManagedFileStore(applicationSupportRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("Stage6UI-\(UUID())"), protectionRequirement: .bestEffort)
            let file = try files.ingest(data: Data("stage6-managed-document".utf8),
                displayName: "stage6.txt", mediaType: "text/plain", in: store)
            let sessions = ConversationSessionStore()
            let observer = Stage6ToolUIObserver()
            _observer = State(initialValue: observer)
            let system = ProcessInfo.processInfo.environment["ZEN_STAGE6_TOOL_UI_TEST"] == "system"
            let registry = try ToolRegistry(tools: system
                ? [Stage6UISystemTool(driver: observer)]
                : [FilesTool(files: files, store: store, sessions: sessions)])
            if system {
                try store.setToolPolicy(toolID: "stage6_system", actionID: "probe", descriptorRevision: "1", mode: .alwaysAllow)
            }
            let arguments = system ? "{}" : try ToolArgumentJSON.normalizedObject(["assetID": file.assetID])
            let provider = Stage6UIProvider(base: FakeProvider(capabilities: [.text, .streaming, .tools]),
                toolName: system ? "stage6_system" : "files",
                arguments: arguments)
            let router = RunEventRouter()
            let runtime = ConversationRuntime(store: store, provider: provider, credentials: credentials,
                onEvent: { [weak router, weak observer] event in
                    await router?.handle(event)
                    await observer?.observe(event)
                }, registerRecoveredRun: { [weak router] runID, conversationID in
                    await router?.registerRecoveredRun(runID: runID, conversationID: conversationID)
                }, toolRegistry: registry, managedFileStore: files)
            let suite = "ZenAgent.Stage6UITest"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            if ProcessInfo.processInfo.environment["ZEN_STAGE6_TOOL_UI_LARGE"] == "1" {
                defaults.set(AppAppearance.dark.rawValue, forKey: "zen.appearance.v1")
            }
            _model = State(initialValue: AppShellModel(dependencies: .init(store: store, credentials: credentials,
                provider: provider, runtime: runtime, router: router, managedFiles: files,
                toolRegistry: registry, sessions: sessions), userDefaults: defaults))
        } catch { fatalError("Stage 6 UI fixture could not assemble: \(error)") }
    }

    var body: some View {
        AppShellRootView(model: model)
            .environment(\.dynamicTypeSize, ProcessInfo.processInfo.environment["ZEN_STAGE6_TOOL_UI_LARGE"] == "1"
                ? .accessibility5 : .large)
            .task {
                guard !opened else { return }
                opened = true
                _ = await model.openConversation(id: "stage6-conversation")
            }
            .overlay(alignment: .topLeading) {
                Text(diagnostic)
                    .font(.system(size: 1)).frame(width: 1, height: 1)
                    .accessibilityIdentifier("stage6-tool-observation")
            }
    }

    private var diagnostic: String {
        _ = observer.revision
        let calls = (try? store.runs(inConversation: "stage6-conversation").flatMap {
            try store.toolCalls(inRun: $0.id)
        }) ?? []
        let call = calls.last
        let grants = (try? store.toolGrants(subject: .parentConversation("stage6-conversation"))) ?? []
        return "state=\(call?.state.rawValue ?? "none");failure=\(call?.failureReason?.rawValue ?? "none");requests=\(observer.requests);executions=\(observer.executions);activeGrants=\(grants.filter { $0.grant.validity == .active }.count)"
    }
}

@MainActor @Observable
private final class Stage6ToolUIObserver {
    var revision = 0
    var requests = 0
    var executions = 0
    var status: ToolSystemPermissionState = .notDetermined
    func observe(_ event: AgentEvent) { revision += 1 }
    func request() { requests += 1; status = .authorized }
    func execute() { executions += 1 }
}

private struct Stage6UISystemTool: ToolSystemPermissionProviding {
    let driver: Stage6ToolUIObserver
    var descriptor: ToolDescriptor {
        ToolDescriptor(id: "stage6_system", displayName: "系统权限测试", description: "Test-only OS capability",
            inputSchema: .object(["type": .string("object"), "additionalProperties": .bool(false)]),
            revision: "1", sideEffect: .none, approvalRequirement: .notRequired,
            actions: [.init(toolID: "stage6_system", actionID: "probe", descriptorRevision: "1",
                risk: .low, allowsAutomaticApproval: true, allowsConversationGrant: true,
                resourceRequirement: .notRequired, egressRequirement: .notRequired)])
    }
    var systemPermissionDescription: String { "仅测试驱动；继续前需要独立同意。" }
    func systemPermissionState(for intent: ToolExecutionIntent) async throws -> ToolSystemPermissionState { await driver.status }
    func systemPermissionStateForSettings() async throws -> ToolSystemPermissionState? { await driver.status }
    func requestSystemPermission(for intent: ToolExecutionIntent) async throws { await driver.request() }
    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try ToolIntentCodec.freeze(descriptor: descriptor, actionID: "probe", normalizedArgumentsJSON: "{}",
            resource: .notRequired, destination: .notRequired,
            approvalDisclosure: .init(toolDisplayName: descriptor.displayName, action: "检查测试能力",
                targetDescription: "本地测试驱动", keyImpact: "请求独立系统同意"))
    }
    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        await driver.execute()
        return .init(content: "stage6-system-result")
    }
}

private struct Stage6UIProvider: ModelProvider {
    let base: FakeProvider
    let toolName: String
    let arguments: String
    var id: ProviderID { base.id }
    var adapterRevision: String { base.adapterRevision }
    var adapterPromptInstructions: String { base.adapterPromptInstructions }
    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] { base.knownModels(for: instance) }
    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        base.descriptor(for: modelID, in: instance)
    }
    func makeRequestConfigSeed(instance: ProviderInstance, modelID: ModelID, credentialBinding: CredentialBindingSnapshot) throws -> RequestConfigSeed {
        RequestConfigSeed(instance: instance, modelID: modelID, credentialBinding: credentialBinding,
            resolvedEndpoint: URL(string: "https://stage6-provider.invalid/chat/completions")!)
    }
    func stream(_ request: ProviderChatRequest, seed: RequestConfigSeed, credentials: any CredentialStoring) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        let continued = request.messages.contains { if case .toolResult = $0 { return true }; return false }
        return AsyncThrowingStream { continuation in
            if continued { continuation.yield(.textDelta("stage6-continued")); continuation.yield(.finish(.stop)) }
            else {
                continuation.yield(.toolCall(.init(id: "stage6-call", index: 0, name: toolName, argumentsJSON: arguments)))
                continuation.yield(.finish(.toolCalls))
            }
            continuation.finish()
        }
    }
}

private final class Stage6UISecrets: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func store(_ secret: SecretValue, for reference: CredentialReference, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }; values["\(reference.id)#\(generation)"] = secret.revealed
    }
    func load(_ reference: CredentialReference, generation: Int) throws -> SecretValue? {
        lock.lock(); defer { lock.unlock() }; return values["\(reference.id)#\(generation)"].map(SecretValue.init)
    }
    func delete(_ reference: CredentialReference, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: "\(reference.id)#\(generation)")
    }
}
#endif
