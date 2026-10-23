import Dispatch
import Foundation
import Testing

@testable import ZenAgent

@Suite("Stage 8 secret-content commit races", .serialized)
struct EnvironmentContentRaceTests {
    @Test("a Secret committed during Plain validation prevents the stale write", .timeLimit(.minutes(1)))
    func plainWriteDoesNotCommitAfterSecret() async throws {
        let fixture = try EnvironmentContentRaceFixture.make()
        defer { fixture.control.releaseProviderLoad() }

        let secret = "race_plain_private_value"
        let contentTask = Task {
            await runBlockedSyncWrite(isUnsafe: {
                ($0 as? EnvironmentError) == .unsafeContent
            }) {
                _ = try fixture.environment.savePlain(key: "RACE_PLAIN", value: secret)
            }
        }
        let race = await finishRace(
            contentTask: contentTask,
            control: fixture.control,
            environment: fixture.environment,
            secret: secret
        )

        #expect(race.providerLoadWasBlocked)
        #expect(race.secretStarted)
        #expect(race.secret == .saved)
        if race.secretCommittedBeforeRelease {
            #expect(race.content == .unsafeContentRejected)
            let values = try fixture.environment.list()
            #expect(!values.contains { item in
                guard case .plain(let value) = item.value else { return false }
                return value.contains(secret)
            })
        } else {
            #expect(race.content == .saved)
        }
    }

    @Test("a Secret committed during Skill instruction validation prevents the stale definition", .timeLimit(.minutes(1)))
    func skillWriteDoesNotCommitAfterSecret() async throws {
        let fixture = try EnvironmentContentRaceFixture.make(blockOnProviderLoad: 3)
        defer { fixture.control.releaseProviderLoad() }

        let secret = "race_skill_private_value"
        let contentTask = Task {
            await runBlockedSyncWrite(isUnsafe: {
                ($0 as? SkillError) == .unsafeContent
            }) {
                _ = try fixture.skills.saveUser(definition: .init(
                    name: "Race skill",
                    summary: "Race fixture",
                    instructions: secret
                ))
            }
        }
        let race = await finishRace(
            contentTask: contentTask,
            control: fixture.control,
            environment: fixture.environment,
            secret: secret
        )

        #expect(race.providerLoadWasBlocked)
        #expect(race.secretStarted)
        #expect(race.secret == .saved)
        if race.secretCommittedBeforeRelease {
            #expect(race.content == .unsafeContentRejected)
            let skills = try fixture.store.skills()
            #expect(!skills.contains { $0.definition.instructions.contains(secret) })
        } else {
            #expect(race.content == .saved)
        }
    }

    @Test("a Secret committed during manual Memory validation prevents the stale revision", .timeLimit(.minutes(1)))
    func manualMemoryDoesNotCommitAfterSecret() async throws {
        let fixture = try EnvironmentContentRaceFixture.make()
        defer { fixture.control.releaseProviderLoad() }

        let secret = "race_memory_private_value"
        let contentTask = Task {
            await runBlockedSyncWrite(isUnsafe: {
                ($0 as? MemoryError) == .unsafeContent
            }) {
                _ = try fixture.memory.save(content: "用户偏好使用 \(secret)")
            }
        }
        let race = await finishRace(
            contentTask: contentTask,
            control: fixture.control,
            environment: fixture.environment,
            secret: secret
        )

        #expect(race.providerLoadWasBlocked)
        #expect(race.secretStarted)
        #expect(race.secret == .saved)
        if race.secretCommittedBeforeRelease {
            #expect(race.content == .unsafeContentRejected)
            let memories = try fixture.store.memories()
            #expect(!memories.contains { $0.content.contains(secret) })
        } else {
            #expect(race.content == .saved)
        }
    }

    @Test("automatic Memory revalidates its last candidate before commit", .timeLimit(.minutes(1)))
    func automaticFormationDoesNotCommitAfterSecret() async throws {
        let fixture = try EnvironmentContentRaceFixture.make(blockOnProviderLoad: nil)
        defer { fixture.control.releaseProviderLoad() }

        let provider = Stage2ScriptedProvider(
            ledger: Stage2ProviderLedger(),
            scripts: [.events([.textDelta("Recorded answer"), .finish(.stop)])]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { event in
                if case .runEnded(_, .completed, _) = event {
                    // Source validation is the first load; with one extracted fact,
                    // the candidate validation is the second and final load.
                    fixture.control.arm(blockOnProviderLoad: 2)
                }
            },
            toolRegistry: .empty
        )
        let conversationID = "race-memory-\(UUID().uuidString)"
        let command = SendCommand(
            conversationID: conversationID,
            text: "我偏好中文回答",
            providerInstanceID: fixture.providerInstanceID,
            modelID: Stage2GateFixture.modelID,
            maxProviderSteps: 4,
            submissionID: UUID().uuidString
        )
        let runID = try await runtime.start(
            command,
            creatingConversationIfMissing: Fixtures.conversation(id: conversationID)
        )
        let completionTask = Task<ContentWriteOutcome, Never> {
            do {
                try await runtime.waitForCompletion(runID: runID)
                return .saved
            } catch {
                return .failed
            }
        }

        let secret = "中文"
        let race = await finishRace(
            contentTask: completionTask,
            control: fixture.control,
            environment: fixture.environment,
            secret: secret
        )

        #expect(race.providerLoadWasBlocked)
        #expect(race.secretStarted)
        #expect(race.secret == .saved)
        let completedRun = try fixture.store.run(id: runID)
        #expect(completedRun?.state == .completed)
        let memories = try fixture.store.memories()
        if race.secretCommittedBeforeRelease {
            #expect(!memories.contains { $0.content.contains(secret) })
        } else {
            #expect(memories.contains { $0.content.contains(secret) })
        }
    }

    @Test("a Secret committed during Tool result redaction cannot leak through the durable result", .timeLimit(.minutes(1)))
    func toolResultDoesNotCommitAfterSecret() async throws {
        let fixture = try EnvironmentContentRaceFixture.make(blockOnProviderLoad: nil)
        defer { fixture.control.releaseProviderLoad() }

        let tool = RaceResultTool(content: "race_tool_private_result", control: fixture.control)
        let registry = try ToolRegistry(tools: [tool])
        try Fixtures.allowAutomaticToolPolicies(in: fixture.store, registry: registry)
        let providerLedger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: providerLedger,
            scripts: [
                .events([
                    .toolCall(.init(
                        id: "race-tool-provider-call",
                        index: 0,
                        name: RaceResultTool.id,
                        argumentsJSON: "{}"
                    )),
                    .finish(.toolCalls),
                ]),
                .events([.textDelta("Continued after local result"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            toolRegistry: registry
        )
        let conversationID = "race-tool-\(UUID().uuidString)"
        let runID = try await runtime.start(SendCommand(
            conversationID: conversationID,
            text: "Run the local result race fixture",
            providerInstanceID: fixture.providerInstanceID,
            modelID: Stage2GateFixture.modelID,
            maxProviderSteps: 4,
            submissionID: UUID().uuidString
        ), creatingConversationIfMissing: Fixtures.conversation(id: conversationID))

        // The tool arms the blocker immediately before returning its raw result.
        // ToolRuntime then resolves the frozen credential and inventory; load 2
        // parks it after the old inventory has been collected.
        let completionTask = Task<ContentWriteOutcome, Never> {
            do {
                try await runtime.waitForCompletion(runID: runID)
                return .saved
            } catch {
                return .failed
            }
        }
        let secret = tool.content
        let race = await finishRace(
            contentTask: completionTask,
            control: fixture.control,
            environment: fixture.environment,
            secret: secret
        )

        #expect(race.providerLoadWasBlocked)
        #expect(race.secretStarted)
        #expect(race.secret == .saved)
        #expect(race.content == .saved)
        let run = try fixture.store.run(id: runID)
        #expect(run?.state == .completed)
        let calls = try fixture.store.toolCalls(inRun: runID)
        let possibleCall = calls.first(where: { $0.providerCallID == "race-tool-provider-call" })
        let call = try #require(possibleCall)
        let possibleStoredResult = try fixture.store.toolResult(toolCallID: call.id)
        let storedResult = try #require(possibleStoredResult)
        let requests = await providerLedger.requestsSnapshot()
        let continuedResults = requests.dropFirst().flatMap { request in
            request.messages.compactMap { message -> String? in
                guard case .toolResult(let toolCallID, let content) = message,
                      toolCallID == "race-tool-provider-call" else { return nil }
                return content
            }
        }
        #expect(continuedResults.count == 1)
        // The pending Secret writer owns the handoff lease before the blocked
        // result is released. Its classification must apply to the later POST,
        // even when the content commit legitimately linearized first.
        #expect(!continuedResults.contains { $0.contains(secret) })
        if race.secretCommittedBeforeRelease {
            #expect(!storedResult.payload.contains(secret))
        } else {
            #expect(storedResult.payload.contains(secret))
        }
    }
}

private enum ContentWriteOutcome: Sendable, Equatable {
    case saved
    case unsafeContentRejected
    case failed
}

private enum SecretSaveOutcome: Sendable, Equatable {
    case saved
    case failed
    case notStarted
}

private struct RaceSynchronization<T: Sendable>: Sendable {
    let providerLoadWasBlocked: Bool
    let secretStarted: Bool
    let secretCommittedBeforeRelease: Bool
    let content: T
    let secret: SecretSaveOutcome
}

private func runBlockedSyncWrite(
    isUnsafe: @escaping @Sendable (Error) -> Bool,
    operation: @escaping @Sendable () throws -> Void
) async -> ContentWriteOutcome {
    await onUnblockedWorker {
        let outcome: ContentWriteOutcome
        do {
            try operation()
            outcome = .saved
        } catch {
            outcome = isUnsafe(error) ? .unsafeContentRejected : .failed
        }
        return outcome
    }
}

/// The deliberately blocking synchronous writer runs on GCD, so its Condition
/// wait never occupies one of Swift concurrency's cooperative executor threads.
private func onUnblockedWorker<T: Sendable>(
    _ operation: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: operation())
        }
    }
}

private func finishRace<T: Sendable>(
    contentTask: Task<T, Never>,
    control: EnvironmentContentRaceControl,
    environment: EnvironmentRuntime,
    secret: String
) async -> RaceSynchronization<T> {
    defer { control.releaseProviderLoad() }

    let loadWasBlocked = await onUnblockedWorker { control.waitUntilProviderLoadIsBlocked(timeout: 5) }
    guard loadWasBlocked else {
        control.releaseProviderLoad()
        let content = await contentTask.value
        return RaceSynchronization(
            providerLoadWasBlocked: false,
            secretStarted: false,
            secretCommittedBeforeRelease: false,
            content: content,
            secret: .notStarted
        )
    }

    let secretTask = Task.detached { () -> SecretSaveOutcome in
        control.markSecretStarted()
        do {
            // Keep the await so this regression remains valid if the handoff
            // writer becomes asynchronous while still compiling against today's
            // synchronous implementation.
            _ = try await environment.saveSecret(key: "RACE_SECRET", value: SecretValue(secret))
            control.recordSecretCompletion(succeeded: true)
            return .saved
        } catch {
            control.recordSecretCompletion(succeeded: false)
            return .failed
        }
    }

    let secretStarted = await onUnblockedWorker { control.waitForSecretStart(timeout: 2) }
    let secretCommittedBeforeRelease = await onUnblockedWorker { control.waitForSecretCompletion(timeout: 2) }
    control.releaseProviderLoad()
    let content = await contentTask.value
    let secretResult = await secretTask.value
    return RaceSynchronization(
        providerLoadWasBlocked: true,
        secretStarted: secretStarted,
        secretCommittedBeforeRelease: secretCommittedBeforeRelease && secretResult == .saved,
        content: content,
        secret: secretResult
    )
}

private struct EnvironmentContentRaceFixture: Sendable {
    let store: PersistenceStore
    let backend: InMemorySecretBackend
    let blockingBackend: BlockingCredentialLoadBackend
    let credentials: CredentialStore
    let environment: EnvironmentRuntime
    let skills: SkillRuntime
    let memory: MemoryRuntime
    let control: EnvironmentContentRaceControl
    let providerReference: CredentialReference
    let providerInstanceID: ProviderInstanceID

    static func make(blockOnProviderLoad: Int? = 1) throws -> Self {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let backend = InMemorySecretBackend()
        let providerReference = CredentialReference(id: "race-provider-\(UUID().uuidString)")
        let providerInstanceID = ProviderInstanceID(rawValue: "race-provider-\(UUID().uuidString)")
        let control = EnvironmentContentRaceControl()
        let blockingBackend = BlockingCredentialLoadBackend(
            backend: backend,
            blockedReference: providerReference,
            control: control
        )
        let credentials = CredentialStore(secrets: blockingBackend, metadataRepository: store)
        try credentials.provision(SecretValue("race_existing_provider_credential"), as: providerReference)
        try store.createProviderInstance(ProviderInstance(
            id: providerInstanceID,
            providerID: .deepSeek,
            displayName: "Race fixture",
            baseURL: URL(string: "https://race-fixture.invalid"),
            configRevision: .initial,
            credentialReference: providerReference
        ))
        if let blockOnProviderLoad {
            control.arm(blockOnProviderLoad: blockOnProviderLoad)
        }

        let environment = EnvironmentRuntime(store: store, credentials: credentials)
        let skills = SkillRuntime(store: store, credentials: credentials, registry: .empty)
        let memory = MemoryRuntime(store: store, credentials: credentials)
        return Self(
            store: store,
            backend: backend,
            blockingBackend: blockingBackend,
            credentials: credentials,
            environment: environment,
            skills: skills,
            memory: memory,
            control: control,
            providerReference: providerReference,
            providerInstanceID: providerInstanceID
        )
    }
}

private final class EnvironmentContentRaceControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var isArmed = false
    private var targetLoad = 1
    private var matchingLoads = 0
    private var providerLoadBlocked = false
    private var providerLoadReleased = false
    private var secretStarted = false
    private var secretFinished = false
    private var secretSucceeded = false

    func arm(blockOnProviderLoad: Int) {
        condition.lock()
        defer { condition.unlock() }
        isArmed = true
        targetLoad = blockOnProviderLoad
        matchingLoads = 0
        providerLoadBlocked = false
        providerLoadReleased = false
        secretStarted = false
        secretFinished = false
        secretSucceeded = false
        condition.broadcast()
    }

    func shouldBlockProviderLoad(reference: CredentialReference, expected: CredentialReference) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard isArmed, reference == expected else { return false }
        matchingLoads += 1
        guard matchingLoads == targetLoad, !providerLoadBlocked else { return false }
        providerLoadBlocked = true
        condition.broadcast()
        return true
    }

    func pauseProviderLoadForControlledWindow() throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(60)
        while !providerLoadReleased {
            guard condition.wait(until: deadline) else { throw EnvironmentContentRaceTimeout() }
        }
    }

    func waitUntilProviderLoadIsBlocked(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !providerLoadBlocked {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func markSecretStarted() {
        condition.lock()
        defer { condition.unlock() }
        secretStarted = true
        condition.broadcast()
    }

    func waitForSecretStart(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !secretStarted {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func waitForSecretCompletion(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !secretFinished {
            guard condition.wait(until: deadline) else { return false }
        }
        return secretSucceeded
    }

    func recordSecretCompletion(succeeded: Bool) {
        condition.lock()
        defer { condition.unlock() }
        secretFinished = true
        secretSucceeded = succeeded
        condition.broadcast()
    }

    func releaseProviderLoad() {
        condition.lock()
        providerLoadReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class BlockingCredentialLoadBackend: SecretBackend, @unchecked Sendable {
    private let backend: any SecretBackend
    private let blockedReference: CredentialReference
    private let control: EnvironmentContentRaceControl

    init(
        backend: any SecretBackend,
        blockedReference: CredentialReference,
        control: EnvironmentContentRaceControl
    ) {
        self.backend = backend
        self.blockedReference = blockedReference
        self.control = control
    }

    func store(_ secret: SecretValue, for reference: CredentialReference, generation: Int) throws {
        try backend.store(secret, for: reference, generation: generation)
    }

    func load(_ reference: CredentialReference, generation: Int) throws -> SecretValue? {
        if control.shouldBlockProviderLoad(reference: reference, expected: blockedReference) {
            try control.pauseProviderLoadForControlledWindow()
        }
        return try backend.load(reference, generation: generation)
    }

    func delete(_ reference: CredentialReference, generation: Int) throws {
        try backend.delete(reference, generation: generation)
    }
}

private struct EnvironmentContentRaceTimeout: Error {}

private struct RaceResultTool: ToolExecutable {
    static let id = "environment_content_race_result"
    let content: String
    let control: EnvironmentContentRaceControl

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            id: Self.id,
            displayName: "Race result fixture",
            description: "Returns a fixed local test result.",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false)
            ]),
            revision: "race-result-v1",
            sideEffect: .none,
            approvalRequirement: .notRequired,
            actions: [ToolPolicyActionMetadata(
                toolID: Self.id,
                actionID: "read",
                descriptorRevision: "race-result-v1",
                risk: .low,
                allowsAutomaticApproval: true,
                allowsConversationGrant: true,
                resourceRequirement: .notRequired,
                egressRequirement: .notRequired
            )]
        )
    }

    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        try ToolArgumentJSON.requireEmptyObject(argumentsJSON)
        return try ToolIntentCodec.freeze(
            descriptor: descriptor,
            actionID: "read",
            normalizedArgumentsJSON: "{}",
            resource: .notRequired,
            destination: .notRequired
        )
    }

    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        control.arm(blockOnProviderLoad: 2)
        return ToolExecutionResult(content: content)
    }
}
