import Foundation
import Testing

@testable import ZenAgent

private actor ProjectionInjectionBox {
    private var injectedRunID: String?
    private var injectionError: String?

    func claim(runID: String) -> Bool {
        guard injectedRunID == nil else { return false }
        injectedRunID = runID
        return true
    }

    func record(message: String) {
        injectionError = message
    }

    func runID() -> String? { injectedRunID }
    func error() -> String? { injectionError }
}

private enum ProjectionDiagnosticsTestError: Error, Equatable {
    case missingRunID
    case injectionFailed(String)
}

private struct ProjectionScenarioResult {
    let store: PersistenceStore
    let runID: String
    let error: ConversationProjectionError?
}

private func runProjectionScenario(
    injectedParts: [(kind: MessagePartKind, payload: String)]
) async throws -> ProjectionScenarioResult {
    let fixture = try I05RuntimeTestFixtures.makeFixture()
    let ledger = I07ProviderLedger()
    let toolLedger = I07ToolLedger()
    let injection = ProjectionInjectionBox()
    let provider = I07ScriptedProvider(
        ledger: ledger,
        instanceID: fixture.instance.id,
        scripts: [
            [
                .toolCall(.init(
                    id: "projection-provider-call",
                    index: 0,
                    name: "echo",
                    argumentsJSON: "{}"
                )),
                .finish(.toolCalls),
            ],
            [
                .textDelta("projection continuation"),
                .finish(.stop),
            ],
        ],
        toolLedger: toolLedger,
        store: fixture.store,
        conversationID: I05RuntimeTestFixtures.conversationID
    )
    let toolRegistry = try ToolRegistry(tools: [
        I07RecordingTool(
            id: "echo",
            approvalRequirement: .notRequired,
            ledger: toolLedger
        ),
    ])
    let runtime = ConversationRuntime(
        store: fixture.store,
        provider: provider,
        credentials: fixture.credentials,
        onEvent: { event in
            guard case .runStateChanged(let runID, .toolRequested) = event else {
                return
            }
            guard await injection.claim(runID: runID) else { return }

            do {
                let response = try fixture.store.ensureAssistantResponse(
                    forRunID: runID,
                    messageID: "assistant-\(runID)"
                )
                for (sequence, injectedPart) in injectedParts.enumerated() {
                    try fixture.store.createPart(
                        MessagePartRecord(
                            id: "projection-injected-\(sequence)",
                            messageID: response.id,
                            sequence: sequence,
                            kind: injectedPart.kind,
                            state: .completed,
                            payload: injectedPart.payload
                        )
                    )
                }
            } catch {
                await injection.record(message: String(describing: error))
            }
        },
        toolRegistry: toolRegistry
    )

    var observedError: ConversationProjectionError?
    do {
        _ = try await runtime.send(I05RuntimeTestFixtures.command())
    } catch let error as ConversationProjectionError {
        observedError = error
    }

    guard let runID = await injection.runID() else {
        throw ProjectionDiagnosticsTestError.missingRunID
    }
    if let injectionError = await injection.error() {
        throw ProjectionDiagnosticsTestError.injectionFailed(injectionError)
    }
    return ProjectionScenarioResult(
        store: fixture.store,
        runID: runID,
        error: observedError
    )
}

@Suite("Conversation projection diagnostics")
struct ProjectionDiagnosticsTests {
    @Test("a malformed tool-call Part preserves its kind and part ID")
    func malformedToolCallPartIsDiagnosable() async throws {
        let result = try await runProjectionScenario(
            injectedParts: [
                (
                    kind: .toolCall,
                    payload: #"{"notToolCall":true}"#
                ),
            ]
        )

        guard case .malformedToolCallPart(let partID) = result.error else {
            #expect(false, "the caller must receive the typed malformed tool-call diagnostic")
            return
        }
        #expect(partID == "projection-injected-0")
        #expect(try result.store.run(id: result.runID)?.state == .failed)
    }

    @Test("a malformed tool-result Part preserves its kind and part ID")
    func malformedToolResultPartIsDiagnosable() async throws {
        let result = try await runProjectionScenario(
            injectedParts: [
                (
                    kind: .toolResult,
                    payload: #"{"notToolResult":true}"#
                ),
            ]
        )

        guard case .malformedToolResultPart(let partID) = result.error else {
            #expect(false, "the caller must receive the typed malformed tool-result diagnostic")
            return
        }
        #expect(partID == "projection-injected-0")
        #expect(try result.store.run(id: result.runID)?.state == .failed)
    }

    @Test("projection decoders ignore additional JSON fields")
    func additionalJSONFieldsRemainForwardCompatible() async throws {
        let result = try await runProjectionScenario(
            injectedParts: [
                (
                    kind: .toolCall,
                    payload: #"{"toolCallID":"unrelated-call","futureField":true}"#
                ),
                (
                    kind: .toolResult,
                    payload: #"{"toolCallID":"unrelated-result","futureField":42}"#
                ),
            ]
        )

        #expect(result.error == nil)
        #expect(try result.store.run(id: result.runID)?.state == .completed)
        let parts = try result.store.parts(ofMessage: "assistant-\(result.runID)")
        #expect(parts.contains { $0.kind == .toolResult })
    }
}
