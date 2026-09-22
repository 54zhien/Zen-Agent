import Foundation

@testable import ZenAgent

struct SideEffectObservation: Sendable, Equatable {
    var toolCallID: String
    var dispatchCount: Int
    var idempotencyKey: String
    var outcome: String
}

actor SideEffectLedger {
    private var observations: [SideEffectObservation] = []

    func record(
        toolCallID: String,
        idempotencyKey: String,
        outcome: String
    ) {
        let count = observations.filter { $0.toolCallID == toolCallID }.count + 1
        observations.append(
            SideEffectObservation(
                toolCallID: toolCallID,
                dispatchCount: count,
                idempotencyKey: idempotencyKey,
                outcome: outcome
            )
        )
    }

    func snapshot() -> [SideEffectObservation] {
        observations
    }
}

struct Stage2SideEffectTool: ToolExecutable {
    let descriptor: ToolDescriptor
    private let ledger: SideEffectLedger
    private let gate: Stage2DispatchGate?

    init(
        ledger: SideEffectLedger = SideEffectLedger(),
        descriptorID: String = "stage2_side_effect",
        gate: Stage2DispatchGate? = nil
    ) {
        self.ledger = ledger
        self.gate = gate
        self.descriptor = ToolDescriptor(
            id: descriptorID,
            displayName: "Stage 2 Side Effect",
            description: "A test-only external write tool.",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
            ]),
            revision: "1",
            sideEffect: .externalWrite,
            approvalRequirement: .required
        )
    }

    func prepare(
        callID: String,
        argumentsJSON: String
    ) throws -> ToolExecutionIntent {
        guard argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" else {
            throw ToolExecutionError.invalidArguments
        }

        return ToolExecutionIntent(
            formatVersion: ToolExecutionIntent.currentFormatVersion,
            toolID: descriptor.id,
            descriptorRevision: descriptor.revision,
            normalizedArgumentsJSON: "{}",
            targetIdentity: callID,
            destinationIdentity: nil
        )
    }

    func execute(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws -> ToolExecutionResult {
        guard
            intent.formatVersion == ToolExecutionIntent.currentFormatVersion,
            intent.toolID == descriptor.id,
            intent.descriptorRevision == descriptor.revision,
            let toolCallID = intent.targetIdentity
        else {
            throw ToolExecutionError.invalidIntent
        }

        await ledger.record(
            toolCallID: toolCallID,
            idempotencyKey: idempotencyKey,
            outcome: "succeeded"
        )

        // The external write has happened by the time `record` returns. The optional
        // gate holds the executor here — after the side effect, before any terminal
        // result — so the closure gate can restart against the same database while
        // this process is still inside the dispatch window. Without a gate the call
        // returns immediately, which is what the I08 crash probes rely on.
        if let gate {
            gate.signalDispatched()
            await gate.waitForRelease()
        }

        return ToolExecutionResult(content: "succeeded")
    }
}
