import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Conversation prompt history")
struct PromptHistoryIntegrationTests {

    @Test("real sends include system instructions and the prior completed text turn")
    func realSendsComposeSystemAndPriorTextHistory() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-text-turns.sqlite")
        defer { Fixtures.cleanUp(url) }

        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([.textDelta("First answer"), .finish(.stop)]),
                .events([.textDelta("Second answer"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: .empty
        )

        _ = try await runtime.send(Stage2GateFixture.command(text: "First question"))
        try components.store.database.write { db in
            try Fixtures.message(
                id: "prompt-history-unlinked-user",
                conversationID: Stage2GateFixture.conversationID,
                role: .user,
                sequence: 2
            ).insert(db)
            try Fixtures.textPart(
                id: "prompt-history-unlinked-part",
                messageID: "prompt-history-unlinked-user",
                text: "Unlinked historical input"
            ).insert(db)
        }
        _ = try await runtime.send(Stage2GateFixture.command(text: "Second question"))

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }

        let firstSystem = systemContent(in: requests[0])
        #expect(firstSystem.contains("Runtime / Safety"))
        #expect(firstSystem.contains("Provider Adapter"))
        #expect(firstSystem.contains("Zen Core defaults"))
        #expect(requests[0].messages.last == .user("First question"))

        #expect(
            requests[1].messages == [
                .system(firstSystem),
                .user("First question"),
                .assistant(content: "First answer", reasoning: nil, toolCalls: []),
                .user("Second question"),
            ],
            "the provider must receive ordered persisted text history plus the current input"
        )
        #expect(
            !requests[1].messages.contains(.user("Unlinked historical input")),
            "an orphan Message without a completed Parent Run must not enter history"
        )
    }

    @Test("reopened history stays scoped and keeps a saved quote after source deletion")
    func reopenedHistoryIsConversationScopedAndPreservesQuoteSnapshots() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-reopen.sqlite")
        defer { Fixtures.cleanUp(url) }

        let services = try await runInitialConversations(at: url)
        let requests = try await runFollowUpAfterReopening(at: url, services: services)
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }

        let system = systemContent(in: requests[0])
        #expect(
            requests[0].messages == [
                .system(system),
                .user("Conversation A first\n\nQuoted context:\nQuoted passage 1:\nFirst snapshot"),
            ]
        )
        #expect(
            requests[1].messages == [
                .system(system),
                .user("Conversation B question"),
            ],
            "another Conversation's messages must not enter this request"
        )
        #expect(
            requests[2].messages == [
                .system(system),
                .user("Conversation A first\n\nQuoted context:\nQuoted passage 1:\nFirst snapshot"),
                .assistant(content: "Answer A1", reasoning: nil, toolCalls: []),
                .user("Conversation A follow-up\n\nQuoted context:\nQuoted passage 1:\nCurrent snapshot"),
            ],
            "a rebuilt runtime must read persisted history and append the current quote once"
        )
    }

    @Test("history omits the entire turn that contains structured tool protocol")
    func historySkipsToolTurnsAsWholeUnits() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-tool-turn.sqlite")
        defer { Fixtures.cleanUp(url) }

        let requests = try await runToolConversation(at: url)
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }

        let system = systemContent(in: requests[0])
        let continuation = requests[1].messages
        #expect(
            continuation.contains {
                guard case .assistant(_, _, let calls) = $0 else { return false }
                return calls.contains { $0.id == "history-tool-call" }
            }
        )
        #expect(
            continuation.contains {
                guard case .toolResult(let callID, _) = $0 else { return false }
                return callID == "history-tool-call"
            },
            "the live continuation must retain the structured call/result pair"
        )

        #expect(
            requests[2].messages == [
                .system(system),
                .user("After tool turn"),
            ],
            "tool-bearing Turns are excluded atomically instead of flattened into text"
        )
        #expect(
            !requests[2].messages.contains {
                if case .toolResult = $0 { return true }
                if case .assistant(_, _, let calls) = $0 { return !calls.isEmpty }
                return false
            }
        )
    }

    @Test("failed turns stay out of history while their persisted records remain intact")
    func failedTextTurnsAreExcludedWithoutDeletingTheirRecords() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-failed-turns.sqlite")
        defer { Fixtures.cleanUp(url) }

        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([.textDelta("First completed answer"), .finish(.stop)]),
                .failure(prefix: []),
                .failure(prefix: [.textDelta("Partial failed output")]),
                .events([.textDelta("Answer after failures"), .finish(.stop)]),
                .events([.textDelta("Final answer"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: .empty
        )

        _ = try await runtime.send(Stage2GateFixture.command(text: "First completed question"))

        let zeroOutputFailureID = try await runtime.send(
            Stage2GateFixture.command(text: "Zero output failure")
        )
        let zeroOutputRun = try #require(try components.store.run(id: zeroOutputFailureID))
        #expect(zeroOutputRun.state == .failed)
        #expect(zeroOutputRun.responseMessageID == nil)
        let zeroOutputTriggerID = try #require(zeroOutputRun.triggerMessageID)

        let partialFailureID = try await runtime.send(
            Stage2GateFixture.command(text: "Partial output failure")
        )
        let partialRun = try #require(try components.store.run(id: partialFailureID))
        #expect(partialRun.state == .failed)
        let partialTriggerID = try #require(partialRun.triggerMessageID)
        let partialResponseID = try #require(partialRun.responseMessageID)
        let partialParts = try components.store.parts(ofMessage: partialResponseID)
        #expect(partialParts.count == 1)
        let partialPart = try #require(partialParts.first)
        #expect(partialPart.state == .failed)
        #expect(try components.store.text(ofPart: partialPart.id) == "Partial failed output")

        let oldMessages = try components.store.messages(
            inConversation: Stage2GateFixture.conversationID
        )
        let oldMessageIDs = oldMessages.map(\.id)
        let oldSequences = oldMessages.map(\.sequence)

        _ = try await runtime.send(Stage2GateFixture.command(text: "Question after failures"))
        _ = try await runtime.send(
            Stage2GateFixture.command(text: "Question after two completed turns")
        )

        let messagesAfterFilter = try components.store.messages(
            inConversation: Stage2GateFixture.conversationID
        )
        #expect(Array(messagesAfterFilter.prefix(oldMessageIDs.count).map(\.id)) == oldMessageIDs)
        #expect(Array(messagesAfterFilter.prefix(oldSequences.count).map(\.sequence)) == oldSequences)
        #expect(try components.store.run(id: zeroOutputFailureID)?.state == .failed)
        #expect(try components.store.run(id: zeroOutputFailureID)?.triggerMessageID
            == zeroOutputTriggerID)
        #expect(try components.store.run(id: zeroOutputFailureID)?.responseMessageID == nil)
        #expect(try text(in: components.store, messageID: zeroOutputTriggerID) == "Zero output failure")
        #expect(try components.store.run(id: partialFailureID)?.state == .failed)
        #expect(try components.store.run(id: partialFailureID)?.responseMessageID == partialResponseID)
        let persistedPartialPart = try #require(try components.store.part(id: partialPart.id))
        #expect(persistedPartialPart.id == partialPart.id)
        #expect(persistedPartialPart.state == partialPart.state)
        #expect(persistedPartialPart.payload == partialPart.payload)
        #expect(try components.store.text(ofPart: partialPart.id) == "Partial failed output")
        #expect(try text(in: components.store, messageID: partialTriggerID) == "Partial output failure")

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 5)
        guard requests.count == 5 else { return }

        let system = systemContent(in: requests[0])
        #expect(
            requests[0].messages == [
                .system(system),
                .user("First completed question"),
            ]
        )
        #expect(
            requests[1].messages == [
                .system(system),
                .user("First completed question"),
                .assistant(content: "First completed answer", reasoning: nil, toolCalls: []),
                .user("Zero output failure"),
            ]
        )
        #expect(
            requests[2].messages == [
                .system(system),
                .user("First completed question"),
                .assistant(content: "First completed answer", reasoning: nil, toolCalls: []),
                .user("Partial output failure"),
            ]
        )
        #expect(
            requests[3].messages == [
                .system(system),
                .user("First completed question"),
                .assistant(content: "First completed answer", reasoning: nil, toolCalls: []),
                .user("Question after failures"),
            ],
            "the first completed turn stays ordered while both failed turns are excluded"
        )
        #expect(
            requests[4].messages == [
                .system(system),
                .user("First completed question"),
                .assistant(content: "First completed answer", reasoning: nil, toolCalls: []),
                .user("Question after failures"),
                .assistant(content: "Answer after failures", reasoning: nil, toolCalls: []),
                .user("Question after two completed turns"),
            ],
            "both completed text turns remain in order after an excluded failure gap"
        )
    }

    @Test("partial output from a cancelled turn is preserved but excluded from next history")
    func cancelledPartialTextTurnIsExcludedWithoutDeletingItsRecords() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-cancelled-turn.sqlite")
        defer { Fixtures.cleanUp(url) }

        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let box = Stage2StreamBox()
        let recorder = Stage2GateEventRecorder()
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .holding(prefix: [.textDelta("Partial cancelled output")], box: box),
                .events([.textDelta("Answer after cancellation"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            onEvent: { event in await recorder.append(event) },
            toolRegistry: .empty
        )

        let cancelledRunID = try await runtime.start(
            Stage2GateFixture.command(text: "Cancelled question")
        )
        await box.waitUntilReady()
        let streamingRunID = await recorder.waitForState(.streaming)
        #expect(streamingRunID == cancelledRunID)
        let partID = await recorder.waitForPartStarted(runID: cancelledRunID)
        try await runtime.stop(runID: cancelledRunID)
        try await runtime.waitForCompletion(runID: cancelledRunID)
        await box.waitUntilCancelled()

        let cancelledRun = try #require(try components.store.run(id: cancelledRunID))
        #expect(cancelledRun.state == .cancelled)
        let triggerID = try #require(cancelledRun.triggerMessageID)
        let responseID = try #require(cancelledRun.responseMessageID)
        let cancelledPart = try #require(try components.store.part(id: partID))
        #expect(cancelledPart.messageID == responseID)
        #expect(cancelledPart.state == .cancelled)
        #expect(try components.store.text(ofPart: partID) == "Partial cancelled output")

        let messagesBeforeFollowUp = try components.store.messages(
            inConversation: Stage2GateFixture.conversationID
        )
        let messageIDsBeforeFollowUp = messagesBeforeFollowUp.map(\.id)

        _ = try await runtime.send(Stage2GateFixture.command(text: "After cancelled turn"))

        let messagesAfterFollowUp = try components.store.messages(
            inConversation: Stage2GateFixture.conversationID
        )
        #expect(
            Array(messagesAfterFollowUp.prefix(messageIDsBeforeFollowUp.count).map(\.id))
                == messageIDsBeforeFollowUp
        )
        #expect(try components.store.run(id: cancelledRunID)?.state == .cancelled)
        #expect(try components.store.run(id: cancelledRunID)?.triggerMessageID == triggerID)
        #expect(try components.store.run(id: cancelledRunID)?.responseMessageID == responseID)
        let persistedCancelledPart = try #require(try components.store.part(id: partID))
        #expect(persistedCancelledPart.id == cancelledPart.id)
        #expect(persistedCancelledPart.state == cancelledPart.state)
        #expect(persistedCancelledPart.payload == cancelledPart.payload)
        #expect(try components.store.text(ofPart: partID) == "Partial cancelled output")

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        let system = systemContent(in: requests[0])
        #expect(requests[0].messages == [.system(system), .user("Cancelled question")])
        #expect(
            requests[1].messages == [.system(system), .user("After cancelled turn")],
            "a cancelled Turn's user and partial assistant output must be excluded together"
        )
    }

    @Test("attachment turns stay out of text history without deleting the saved reference")
    func attachmentTurnIsExcludedWithoutDeletingItsRecords() async throws {
        let url = try Fixtures.scratchPath(name: "prompt-history-attachment-turn.sqlite")
        defer { Fixtures.cleanUp(url) }
        let supportRoot = temporarySupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let managedFiles = ManagedFileStore(
            applicationSupportRoot: supportRoot,
            protectionRequirement: .bestEffort
        )
        let descriptor = try managedFiles.ingest(
            data: Data("historical attachment bytes".utf8),
            displayName: "historical.txt",
            mediaType: "text/plain",
            in: components.store
        )
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([.textDelta("Attachment answer"), .finish(.stop)]),
                .events([.textDelta("Next answer"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: .empty,
            managedFileStore: managedFiles
        )
        var attachmentTurn = Stage2GateFixture.command(text: "Question with attachment")
        attachmentTurn.attachments = [sendAttachment(for: descriptor)]

        let attachmentRunID = try await runtime.send(attachmentTurn)
        let attachmentRun = try #require(try components.store.run(id: attachmentRunID))
        #expect(attachmentRun.state == .completed)
        let triggerID = try #require(attachmentRun.triggerMessageID)
        let storedAttachment = try #require(
            try components.store.attachments(forMessage: triggerID).first
        )
        #expect(storedAttachment.assetID == descriptor.assetID)
        #expect(storedAttachment.versionID == descriptor.versionID)

        _ = try await runtime.send(Stage2GateFixture.command(text: "After attachment turn"))

        #expect(try components.store.run(id: attachmentRunID)?.state == .completed)
        #expect(try components.store.attachments(forMessage: triggerID).first?.id == storedAttachment.id)
        #expect(try components.store.attachments(forMessage: triggerID).first?.assetID == descriptor.assetID)
        #expect(try components.store.attachments(forMessage: triggerID).first?.versionID == descriptor.versionID)

        let requests = await ledger.requestsSnapshot()
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        let system = systemContent(in: requests[0])
        #expect(
            requests[1].messages == [.system(system), .user("After attachment turn")],
            "a turn with an attachment is excluded as one unit from text-only history"
        )
    }

    private struct Services: Sendable {
        let credentials: CredentialStore
        let provider: Stage2ScriptedProvider
        let ledger: Stage2ProviderLedger
    }

    private func runInitialConversations(at url: URL) async throws -> Services {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        try insertQuoteSource(in: components.store)
        try components.store.database.write { db in
            try Fixtures.conversation(id: "prompt-history-other-conversation").insert(db)
        }

        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([.textDelta("Answer A1"), .finish(.stop)]),
                .events([.textDelta("Answer B1"), .finish(.stop)]),
                .events([.textDelta("Answer A2"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: .empty
        )

        var first = Stage2GateFixture.command(text: "Conversation A first")
        first.references = [quote(id: "quote-a1", snapshot: "First snapshot")]
        let firstRunID = try await runtime.send(first)
        let firstTriggerID = try #require(
            try components.store.run(id: firstRunID)?.triggerMessageID
        )
        let savedQuote = try #require(
            try components.store.quoteReferences(forMessageID: firstTriggerID).first
        )
        try components.store.beginDeletion(conversationID: "prompt-history-quote-source")
        try components.store.finalizeDeletion(conversationID: "prompt-history-quote-source")
        let quoteSourceAvailable = try components.store.quoteSourceIsAvailable(savedQuote)
        #expect(!quoteSourceAvailable)
        #expect(
            try components.store.quoteReferences(forMessageID: firstTriggerID).map(\.snapshot)
                == ["First snapshot"]
        )

        var other = Stage2GateFixture.command(text: "Conversation B question")
        other.conversationID = "prompt-history-other-conversation"
        _ = try await runtime.send(other)

        return Services(
            credentials: components.credentials,
            provider: provider,
            ledger: ledger
        )
    }

    private func runFollowUpAfterReopening(
        at url: URL,
        services: Services
    ) async throws -> [ProviderChatRequest] {
        let store = try Stage2GateFixture.reopen(url)
        let runtime = ConversationRuntime(
            store: store,
            provider: services.provider,
            credentials: services.credentials,
            toolRegistry: .empty
        )
        var followUp = Stage2GateFixture.command(text: "Conversation A follow-up")
        followUp.references = [quote(id: "quote-a2", snapshot: "Current snapshot")]
        _ = try await runtime.send(followUp)
        return await services.ledger.requestsSnapshot()
    }

    private func runToolConversation(at url: URL) async throws -> [ProviderChatRequest] {
        let components = try Stage2GateFixture.makeDiskComponents(at: url)
        let ledger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(
            ledger: ledger,
            scripts: [
                .events([
                    .toolCall(ProviderToolCall(
                        id: "history-tool-call",
                        index: 0,
                        name: CalculatorTool.toolID,
                        argumentsJSON: #"{"expression":"6*7"}"#
                    )),
                    .finish(.toolCalls),
                ]),
                .events([.textDelta("Tool turn answer"), .finish(.stop)]),
                .events([.textDelta("Follow-up answer"), .finish(.stop)]),
            ]
        )
        let runtime = ConversationRuntime(
            store: components.store,
            provider: provider,
            credentials: components.credentials,
            toolRegistry: try ToolRegistry(tools: [CalculatorTool()])
        )
        _ = try await runtime.send(Stage2GateFixture.command(text: "Run calculator"))
        _ = try await runtime.send(Stage2GateFixture.command(text: "After tool turn"))
        return await ledger.requestsSnapshot()
    }

    private func insertQuoteSource(in store: PersistenceStore) throws {
        try store.database.write { db in
            try Fixtures.conversation(id: "prompt-history-quote-source").insert(db)
            try Fixtures.message(
                id: "prompt-history-quote-message",
                conversationID: "prompt-history-quote-source"
            ).insert(db)
            try MessagePartRecord(
                id: "prompt-history-quote-part",
                messageID: "prompt-history-quote-message",
                sequence: 0,
                kind: .text,
                state: .completed,
                payload: try PersistenceStore.encodeTextPayload(.init(text: "Source text"))
            ).insert(db)
        }
    }

    private func quote(id: String, snapshot: String) -> QuoteReference {
        QuoteReference(
            id: id,
            source: QuoteSourceLocator(
                sourceConversationID: "prompt-history-quote-source",
                sourceMessageID: "prompt-history-quote-message",
                sourcePartID: "prompt-history-quote-part",
                range: QuoteTextRange(utf16Start: 0, utf16Length: 6)
            ),
            snapshot: snapshot,
            createdAt: Fixtures.epoch
        )
    }

    private func text(in store: PersistenceStore, messageID: String) throws -> String {
        try store.parts(ofMessage: messageID)
            .filter { $0.kind == .text }
            .compactMap { try store.text(ofPart: $0.id) }
            .joined()
    }

    private func sendAttachment(for descriptor: ManagedFileDescriptor) -> SendAttachment {
        SendAttachment(
            assetID: descriptor.assetID,
            versionID: descriptor.versionID,
            fingerprint: descriptor.fingerprint,
            kind: .file,
            displayName: descriptor.displayName
        )
    }

    private func temporarySupportRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptHistory-\(UUID().uuidString)", isDirectory: true)
    }

    private func systemContent(in request: ProviderChatRequest) -> String {
        guard let first = request.messages.first,
              case .system(let content) = first
        else {
            Issue.record("the provider request must begin with the composed system message")
            return ""
        }
        return content
    }
}
