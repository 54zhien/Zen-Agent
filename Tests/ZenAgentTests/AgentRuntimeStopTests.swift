import Foundation
import Testing

@testable import ZenAgent

/// A provider stream that keeps its continuation alive after the first delta. The
/// runtime must cancel it on Stop and discard anything yielded after stopping.
final class I05BlockingStreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ProviderStreamEvent, Error>.Continuation?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellationCount = 0

    func makeStream() -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            let waiters = readyWaiters
            readyWaiters.removeAll()
            lock.unlock()

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.recordCancellation()
            }
            continuation.yield(.textDelta("partial"))
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilReady() async {
        lock.lock()
        if continuation != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if self.continuation != nil {
                lock.unlock()
                continuation.resume()
            } else {
                readyWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func yieldLateDelta() {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(.textDelta(" late"))
    }

    func waitUntilCancelled() async {
        lock.lock()
        if cancellationCount > 0 {
            lock.unlock()
            return
        }
        lock.unlock()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if cancellationCount > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                cancellationWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func recordCancellation() {
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

struct I05BlockingProvider: ModelProvider {
    let box: I05BlockingStreamBox
    let instanceID: ProviderInstanceID

    var id: ProviderID { .deepSeek }
    var adapterRevision: String { "i05-blocking-provider.v1" }
    var adapterPromptInstructions: String { "" }

    func knownModels(for instance: ProviderInstance) -> [ModelDescriptor] {
        [ModelDescriptor(
            id: I05RuntimeTestFixtures.modelID,
            providerInstanceID: instance.id,
            displayName: "Fake model",
            capabilities: [.text, .streaming]
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
            resolvedEndpoint: URL(string: "https://fake.invalid/chat/completions")!
        )
    }

    func stream(
        _ request: ProviderChatRequest,
        seed: RequestConfigSeed,
        credentials: any CredentialStoring
    ) async throws -> AsyncThrowingStream<ProviderStreamEvent, Error> {
        box.makeStream()
    }
}

@Suite("Agent runtime stop")
struct AgentRuntimeStopTests {

    @Test("Stop cancels the provider, preserves the partial, and releases the slot only at cancellation")
    func stopIsARealRunOutcome() async throws {
        let fixture = try I05RuntimeTestFixtures.makeFixture()
        let box = I05BlockingStreamBox()
        let provider = I05BlockingProvider(box: box, instanceID: fixture.instance.id)
        let recorder = I05EventRecorder()
        let runtime = ConversationRuntime(
            store: fixture.store,
            provider: provider,
            credentials: fixture.credentials,
            onEvent: { event in await recorder.append(event) }
        )

        let command = I05RuntimeTestFixtures.command()
        let sendTask = Task { try await runtime.send(command) }
        await box.waitUntilReady()
        let runID = await recorder.waitForState(.streaming)

        let stopTask = Task { try await runtime.stop(runID: runID) }
        await recorder.waitForState(.stopping)

        box.yieldLateDelta()

        var secondSendFailure: Error?
        do {
            _ = try await runtime.send(
                I05RuntimeTestFixtures.command(text: "second send")
            )
        } catch {
            secondSendFailure = error
        }
        #expect(secondSendFailure != nil, "stopping still owns the active conversation slot")

        _ = try await stopTask.value
        _ = try await sendTask.value
        await box.waitUntilCancelled()

        let run = try fixture.store.run(id: runID)
        #expect(run?.state == .cancelled)
        #expect(run?.endReason == .cancelledByUser)
        #expect(run?.activeSlot == nil, "the slot is released by the cancelled terminal transition")

        guard let responseID = run?.responseMessageID else {
            #expect(false, "the first provider delta must create the assistant response")
            return
        }
        let parts = try fixture.store.parts(ofMessage: responseID)
        #expect(parts.count == 1)
        #expect(parts[0].state == .cancelled)
        #expect(try fixture.store.text(ofPart: parts[0].id) == "partial")
        #expect(
            !(try fixture.store.text(ofPart: parts[0].id)?.contains("late") ?? false),
            "late provider output after stopping must not mutate the partial"
        )
    }
}
