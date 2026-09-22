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

private enum ProjectionDatabaseInjection {
    case none
    case projectionPersistenceFailure
    case terminalizationFailure
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
    injectedParts: [(kind: MessagePartKind, payload: String)],
    databaseInjection: ProjectionDatabaseInjection = .none
) async throws -> ProjectionScenarioResult {
    let fixture = try I05RuntimeTestFixtures.makeFixture()
    try installProjectionDatabaseInjection(
        databaseInjection,
        in: fixture.store
    )
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

private func installProjectionDatabaseInjection(
    _ injection: ProjectionDatabaseInjection,
    in store: PersistenceStore
) throws {
    try store.database.write { db in
        switch injection {
        case .none:
            break

        case .projectionPersistenceFailure:
            try db.execute(
                sql: """
                    CREATE TRIGGER i07_fail_projection_part_insert
                    BEFORE INSERT ON messagePart
                    WHEN NEW.id LIKE 'tool-call-%'
                    BEGIN
                        SELECT RAISE(ABORT, 'I07 injected projection persistence failure');
                    END
                    """
            )

        case .terminalizationFailure:
            try db.execute(
                sql: """
                    CREATE TRIGGER i07_fail_projection_terminalization
                    BEFORE UPDATE OF state ON agentRun
                    WHEN NEW.state = 'failed'
                    BEGIN
                        SELECT RAISE(ABORT, 'I07 injected terminalization write failure');
                    END
                    """
            )

        }
    }
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

    @Test("a CAS reread of the expected state reports terminalization failure")
    func casVerificationWithExpectedStateReportsTerminalizationFailure() {
        let primary = ConversationProjectionError.malformedToolCallPart("projection-injected-0")
        let transitionError = ProjectionDiagnosticsTestError.injectionFailed("CAS transition failed")
        let verdict = AgentRuntime.casVerificationVerdict(
            latestState: .executingTools,
            expectedState: .executingTools,
            primary: primary,
            transitionError: transitionError
        )

        guard case .terminalizationFailed(let actualPrimary, let reason) = verdict else {
            #expect(false, "an unchanged CAS reread must report terminalization failure")
            return
        }
        #expect(actualPrimary == primary)
        #expect(reason == String(describing: transitionError))
    }

    @Test("a CAS reread of a terminal state preserves the primary diagnostic")
    func casVerificationWithTerminalRereadPreservesPrimaryDiagnostic() {
        let primary = ConversationProjectionError.malformedToolCallPart("projection-injected-0")
        let transitionError = ProjectionDiagnosticsTestError.injectionFailed("CAS transition failed")
        let verdict = AgentRuntime.casVerificationVerdict(
            latestState: .completed,
            expectedState: .executingTools,
            primary: primary,
            transitionError: transitionError
        )

        #expect(verdict == nil)
        #expect((verdict ?? primary) == primary)
    }

    @Test("a CAS reread of another active state reports terminalization failure")
    func casVerificationWithActiveRereadReportsTerminalizationFailure() {
        let primary = ConversationProjectionError.malformedToolCallPart("projection-injected-0")
        let transitionError = ProjectionDiagnosticsTestError.injectionFailed("CAS transition failed")
        let verdict = AgentRuntime.casVerificationVerdict(
            latestState: .stopping,
            expectedState: .executingTools,
            primary: primary,
            transitionError: transitionError
        )

        guard case .terminalizationFailed(let actualPrimary, let reason) = verdict else {
            #expect(false, "an active CAS reread must report terminalization failure")
            return
        }
        #expect(actualPrimary == primary)
        #expect(reason.contains("CAS verification found active state stopping"))
    }

    @Test("a real projection write failure remains a persistence diagnostic")
    func projectionPersistenceFailureIsDiagnosable() async throws {
        let result = try await runProjectionScenario(
            injectedParts: [
                (
                    kind: .toolCall,
                    payload: #"{"toolCallID":"unrelated-call"}"#
                ),
            ],
            databaseInjection: .projectionPersistenceFailure
        )

        guard case .persistenceFailure(let reason) = result.error else {
            #expect(false, "a projection write failure must remain a persistence diagnostic")
            return
        }
        #expect(reason.contains("I07 injected projection persistence failure"))
        #expect(try result.store.run(id: result.runID)?.state == .failed)
    }

    @Test("a real terminalization write failure retains its primary diagnostic")
    func terminalizationFailureRetainsPrimaryDiagnostic() async throws {
        let result = try await runProjectionScenario(
            injectedParts: [
                (
                    kind: .toolCall,
                    payload: #"{"notToolCall":true}"#
                ),
            ],
            databaseInjection: .terminalizationFailure
        )

        guard case .terminalizationFailed(let primary, let reason) = result.error else {
            #expect(false, "a failed terminalization write must be reported as terminalizationFailed")
            return
        }
        guard case .malformedToolCallPart(let partID) = primary else {
            #expect(false, "terminalization failure must carry the original projection diagnostic")
            return
        }
        #expect(partID == "projection-injected-0")
        #expect(reason.contains("I07 injected terminalization write failure"))
    }
}
