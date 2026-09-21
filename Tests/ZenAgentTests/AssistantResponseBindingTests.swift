import Foundation
import Testing

@testable import ZenAgent

@Suite("Assistant response binding")
struct AssistantResponseBindingTests {

    private func makeStore() throws -> PersistenceStore {
        PersistenceStore(database: try ZenDatabase.inMemory())
    }

    @Test("creates one assistant response and reuses its binding")
    func createsAndReusesAssistantResponse() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "user-1", runID: "run-1")
        )

        let now = Date(timeIntervalSince1970: 1_760_000_100)
        let first = try store.ensureAssistantResponse(
            forRunID: "run-1",
            messageID: "assistant-1",
            at: now
        )

        #expect(first.id == "assistant-1")
        #expect(first.conversationID == "c1")
        #expect(first.role == .assistant)
        #expect(first.sequence == 1)

        let second = try store.ensureAssistantResponse(
            forRunID: "run-1",
            messageID: "assistant-2",
            at: now
        )

        #expect(second == first)
        #expect(try store.run(id: "run-1")?.responseMessageID == "assistant-1")
        #expect(try store.messages(inConversation: "c1").count == 2)
    }

    @Test("missing run is reported as a typed failure")
    func missingRunIsTypedFailure() throws {
        let store = try makeStore()
        var failure: Error?

        do {
            _ = try store.ensureAssistantResponse(
                forRunID: "missing-run",
                messageID: "assistant-1"
            )
        } catch {
            failure = error
        }

        #expect(failure as? PersistenceError == .runNotFound("missing-run"))
    }

    @Test("a terminal run cannot create its first assistant response")
    func terminalRunCannotCreateFirstResponse() throws {
        let store = try makeStore()
        try store.commitUserTurnAndCreateParentRun(
            Fixtures.send(messageID: "user-1", runID: "run-1")
        )
        try store.transitionRun(id: "run-1", expectedState: .preparing, to: .requestingModel)
        try store.transitionRun(id: "run-1", expectedState: .requestingModel, to: .streaming)
        try store.transitionRun(
            id: "run-1",
            expectedState: .streaming,
            to: .completed,
            endReason: .completed
        )

        var failure: Error?
        do {
            _ = try store.ensureAssistantResponse(
                forRunID: "run-1",
                messageID: "assistant-1"
            )
        } catch {
            failure = error
        }

        guard let persistenceError = failure as? PersistenceError else {
            #expect(false, "expected a typed PersistenceError")
            return
        }
        if case .invalidTransition = persistenceError {
            // Expected: a terminal run cannot acquire its first response binding.
        } else {
            #expect(false, "expected invalidTransition, got \(persistenceError)")
        }
        #expect(try store.messages(inConversation: "c1").count == 1)
    }
}
