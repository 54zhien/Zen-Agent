import Foundation

@testable import ZenAgent

/// Fixtures for the Stage 2 closure gate.
///
/// The gate exists to prove the *whole* stack closes, so it runs the real
/// `ConversationRuntime` and `AgentRuntime` against a real file-backed store. That is
/// why this file builds a disk fixture instead of reusing the in-memory I05 one.
///
/// What it deliberately does **not** rebuild is the side-effect tool and its ledger.
/// Those stay shared with the I08 crash probes: a gate that re-declares the artifact it
/// is validating proves nothing about the artifact under test.
enum Stage2GateFixture {

    static let conversationID = "stage2-gate-conversation"
    static let instanceID = ProviderInstanceID(rawValue: "stage2-gate-instance")
    static let modelID = ModelID(rawValue: "stage2-gate-model")
    static let credentialReference = CredentialReference(id: "stage2-gate-credential")
    static let conversationTitle = "Stage 2 closure gate"
    static let maxProviderSteps = 4

    struct Components {
        var url: URL
        var store: PersistenceStore
        var credentials: CredentialStore
        var instance: ProviderInstance
    }

    /// A temporary on-disk database holding one visible conversation, one provider
    /// instance and one active credential.
    ///
    /// Every gate runs against this rather than against `ZenDatabase.inMemory()`, so
    /// "this survives a restart" is a claim the database can actually falsify.
    static func makeDiskComponents(at url: URL) throws -> Components {
        let store = PersistenceStore(
            database: try ZenDatabase.open(
                at: url.path(),
                migrator: Migrations.makeMigrator()
            )
        )
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(
            SecretValue("stage2-gate-secret"),
            as: credentialReference
        )

        let instance = ProviderInstance(
            id: instanceID,
            providerID: .deepSeek,
            displayName: "Stage 2 gate provider",
            baseURL: URL(string: "https://stage2-gate.invalid"),
            configRevision: .initial,
            credentialReference: credentialReference
        )
        try store.createProviderInstance(instance)

        var conversation = Fixtures.conversation(id: conversationID)
        conversation.title = conversationTitle
        let persistedConversation = conversation

        try store.database.write { db in
            try persistedConversation.insert(db)
        }

        return Components(
            url: url,
            store: store,
            credentials: credentials,
            instance: instance
        )
    }

    /// A second connection to the same file. Nothing is handed over in memory, which is
    /// the entire point: this is what stands in for a new process.
    static func reopen(_ url: URL) throws -> PersistenceStore {
        PersistenceStore(
            database: try ZenDatabase.open(
                at: url.path(),
                migrator: Migrations.makeMigrator()
            )
        )
    }

    static func command(text: String) -> SendCommand {
        SendCommand(
            conversationID: conversationID,
            text: text,
            providerInstanceID: instanceID,
            modelID: modelID,
            maxProviderSteps: maxProviderSteps
        )
    }
}

/// Every request the runtime actually built, in order.
///
/// An assertion about *what the model was told* has to read the request the runtime
/// produced. Reconstructing it in the test would only assert that the test and the
/// runtime share an author.
actor Stage2ProviderLedger {
    private var requests: [ProviderChatRequest] = []

    func record(_ request: ProviderChatRequest) -> Int {
        requests.append(request)
        return requests.count - 1
    }

    func requestsSnapshot() -> [ProviderChatRequest] { requests }
}

/// A provider stream the test drives by hand.
///
/// It yields a scripted prefix and then holds the continuation open, so "the provider
/// is still talking" is a state the test *decides* rather than a race it hopes for.
/// That is what makes the Stop window and the late-output assertion deterministic
/// instead of timing-dependent.
final class Stage2StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationCount = 0

    func makeStream(
        prefix: [ProviderStreamEvent]
    ) -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            let waiters = readyWaiters
            readyWaiters.removeAll()
            lock.unlock()

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.noteCancellation()
            }
            for event in prefix {
                continuation.yield(event)
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    /// How many times the runtime has torn this stream down. A Stop that leaves the
    /// provider talking has not stopped anything.
    var cancellations: Int { lock.withLock { cancellationCount } }

    /// Output the provider produces after the run has already stopped. Producing it is
    /// the only way to prove the runtime refuses it.
    func yieldLate(_ event: ProviderStreamEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    func waitUntilReady() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let alreadyReady = lock.withLock {
                guard continuation == nil else { return true }
                readyWaiters.append(waiter)
                return false
            }
            if alreadyReady {
                waiter.resume()
            }
        }
    }

    func waitUntilCancelled() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let alreadyCancelled = lock.withLock {
                guard cancellationCount == 0 else { return true }
                cancellationWaiters.append(waiter)
                return false
            }
            if alreadyCancelled {
                waiter.resume()
            }
        }
    }

    private func noteCancellation() {
        lock.lock()
        cancellationCount += 1
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// One scripted provider answer.
enum Stage2ProviderScript: Sendable {
    /// Every event for this request, delivered immediately.
    case events([ProviderStreamEvent])
    /// Yields `prefix`, then keeps the stream open until the test decides otherwise.
    case holding(prefix: [ProviderStreamEvent], box: Stage2StreamBox)
}

/// A provider that answers each request from a script and records what it was asked.
///
/// It is deliberately not a generated responder. A gate whose claim is "exactly one
/// more request, carrying exactly this continuation" needs the request itself to be
/// inspectable, not merely the run's final state.
struct Stage2ScriptedProvider: ModelProvider {
    let ledger: Stage2ProviderLedger
    let scripts: [Stage2ProviderScript]

    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "stage2-gate-scripted-provider.v1" }
    var adapterPromptInstructions: String { "" }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: Stage2GateFixture.modelID,
            providerInstanceID: instance.id,
            displayName: "Stage 2 gate model",
            capabilities: [.text, .streaming, .tools]
        )]
    }

    func descriptor(for modelID: ModelID, in instance: ProviderInstance) -> ModelDescriptor? {
        knownModels(for: instance).first { $0.id == modelID }
    }

    func makeRequestConfigSeed(
        instance: ProviderInstance,
        modelID: ModelID,
        credentialBinding: CredentialBindingSnapshot
    ) throws -> RequestConfigSeed {
        guard descriptor(for: modelID, in: instance) != nil else {
            throw ProviderError.invalidRequest("unknown model")
        }
        return RequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding,
            // No gate is allowed to reach the network, so the endpoint is
            // deliberately unroutable rather than merely unused.
            resolvedEndpoint: URL(string: "https://stage2-gate.invalid/chat/completions")!
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        _ = seed
        _ = credentials
        let index = await ledger.record(request)
        switch scripts[min(index, scripts.count - 1)] {
        case .events(let events):
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        case .holding(let prefix, let box):
            return box.makeStream(prefix: prefix)
        }
    }
}

/// The release barrier that holds Gate C inside the dispatch window.
///
/// `Stage2SideEffectTool` signals here once the external write has happened and then
/// waits, so the test can recover the same database from a second runtime while the
/// first one is still holding a dispatched, non-terminal ToolCall.
final class Stage2DispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatched = false
    private var released = false
    private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// The external write has happened and the dispatch marker is durable.
    func signalDispatched() {
        lock.lock()
        dispatched = true
        let waiters = dispatchWaiters
        dispatchWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Holds the executor inside the dispatch window until `release()`.
    func waitForRelease() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let alreadyReleased = lock.withLock {
                guard !released else { return true }
                releaseWaiters.append(waiter)
                return false
            }
            if alreadyReleased {
                waiter.resume()
            }
        }
    }

    func waitUntilDispatched() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let alreadyDispatched = lock.withLock {
                guard !dispatched else { return true }
                dispatchWaiters.append(waiter)
                return false
            }
            if alreadyDispatched {
                waiter.resume()
            }
        }
    }

    /// Lets the blocked executor finish. Gate C uses this to make the *late* completion
    /// lose its compare-and-swap against the recovery verdict.
    func release() {
        lock.lock()
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// Records the business events the runtime publishes, and can park the runtime inside
/// one of them.
///
/// Waiting on one of these is how a gate synchronises without a clock. It is also
/// durable evidence: `ConversationRuntime` publishes an event only after its own
/// persistence apply has returned, so observing an event is observing a committed row.
///
/// Kept separate from `I05EventRecorder` rather than extending it, because the gate
/// needs an approval waiter and a park that no I05 suite has a use for, and adding them
/// would mean editing another increment's fixture to serve this one.
actor Stage2GateEventRecorder {
    private var events: [AgentEvent] = []
    private var stateWaiters: [(state: RunState, continuation: CheckedContinuation<String, Never>)] = []
    private var partWaiters: [(runID: String, continuation: CheckedContinuation<String, Never>)] = []
    private var approvalWaiters: [CheckedContinuation<String, Never>] = []
    private var parkingState: RunState?
    private var hasParked = false
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private var parkRelease: CheckedContinuation<Void, Never>?

    /// Parks the runtime inside its own projection of `state`, once, until
    /// `releasePark()`.
    ///
    /// This is what turns the stopping window from a race into a state. `AgentRuntime`
    /// awaits its projection before it cancels the provider task, so a runtime parked
    /// here has a durable `stopping` row, still owns the conversation's active slot, and
    /// provably has not started its terminal transition. Without the park, "the second
    /// send is rejected while stopping" is a race against cancellation settling.
    func parkOnState(_ state: RunState) {
        parkingState = state
    }

    func waitUntilParked() async {
        guard !hasParked else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            parkWaiters.append(waiter)
        }
    }

    func releasePark() {
        let release = parkRelease
        parkRelease = nil
        release?.resume()
    }

    func append(_ event: AgentEvent) async {
        events.append(event)

        switch event {
        case .runStateChanged(let runID, let state):
            let ready = stateWaiters.filter { $0.state == state }
            stateWaiters.removeAll { $0.state == state }
            for waiter in ready {
                waiter.continuation.resume(returning: runID)
            }

        case .messagePartStarted(let runID, _, let partID, _):
            let ready = partWaiters.filter { $0.runID == runID }
            partWaiters.removeAll { $0.runID == runID }
            for waiter in ready {
                waiter.continuation.resume(returning: partID)
            }

        case .approvalRequired(_, let toolCallID):
            let ready = approvalWaiters
            approvalWaiters.removeAll()
            for waiter in ready {
                waiter.resume(returning: toolCallID)
            }

        case .runAccepted, .messagePartDelta, .messagePartCompleted, .toolCallChanged, .runEnded:
            break
        }

        guard let parkingState,
              case .runStateChanged(_, let state) = event,
              state == parkingState
        else { return }

        // Park exactly once: the state is consumed here rather than left armed for a
        // later run that happens to pass through it.
        self.parkingState = nil
        hasParked = true
        let waiters = parkWaiters
        parkWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            parkRelease = waiter
        }
    }

    func waitForState(_ state: RunState) async -> String {
        if let runID = events.compactMap({ event -> String? in
            guard case .runStateChanged(let runID, let eventState) = event,
                  eventState == state
            else { return nil }
            return runID
        }).first {
            return runID
        }

        return await withCheckedContinuation { continuation in
            stateWaiters.append((state, continuation))
        }
    }

    /// The durable part id of the run's first started part.
    func waitForPartStarted(runID: String) async -> String {
        if let partID = events.compactMap({ event -> String? in
            guard case .messagePartStarted(let eventRunID, _, let partID, _) = event,
                  eventRunID == runID
            else { return nil }
            return partID
        }).first {
            return partID
        }

        return await withCheckedContinuation { continuation in
            partWaiters.append((runID, continuation))
        }
    }

    /// The durable ToolCall id whose approval the runtime is waiting on.
    func waitForApproval() async -> String {
        if let toolCallID = events.compactMap({ event -> String? in
            guard case .approvalRequired(_, let toolCallID) = event else { return nil }
            return toolCallID
        }).first {
            return toolCallID
        }

        return await withCheckedContinuation { continuation in
            approvalWaiters.append(continuation)
        }
    }
}
