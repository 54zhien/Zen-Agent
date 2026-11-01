#if DEBUG
import Foundation
import GRDB

enum ConversationPreviewUITestSeed {
    static func seedAuthenticationCard(
        in store: PersistenceStore,
        credentialReference: CredentialReference,
        credentialFailureAt: Date
    ) throws {
        let conversationID = "auth-card-ui-conversation"
        let runID = "auth-card-ui-run"
        let providerID = ProviderInstanceID(rawValue: "reauth-ui-account")
        let modelID = ModelID(rawValue: "fake-model")
        let createdAt = credentialFailureAt.addingTimeInterval(-60)
        let triggerMessageID = "auth-card-ui-trigger"
        let provider = FakeProvider()
        guard let instance = try store.providerInstance(id: providerID) else {
            throw PersistenceError.providerInstanceNotFound(providerID)
        }
        let credentialBinding = CredentialBindingSnapshot(reference: credentialReference, generation: 1)
        let requestConfigSeed = try provider.makeRequestConfigSeed(
            instance: instance,
            modelID: modelID,
            credentialBinding: credentialBinding
        )
        let executionSnapshot = try ExecutionSnapshotCodec.encode(RunExecutionSnapshot(
            providerID: provider.id,
            providerAdapterRevision: provider.adapterRevision,
            prompt: PromptExecutionSnapshot(
                runtimeSafetyBaseline: PromptTemplateCatalog.currentRuntimeSafetyRevision,
                zenCore: PromptTemplateCatalog.currentZenCoreRevision,
                providerAdapterInstructions: provider.adapterPromptInstructions
            ),
            modelCapabilities: [.text, .streaming, .reasoning],
            exposedTools: [],
            maxProviderSteps: 4
        ))
        try store.saveMetadata(CredentialMetadata(
            reference: credentialReference,
            bindingGeneration: 1,
            principalFingerprint: nil,
            status: .active,
            updatedAt: credentialFailureAt.addingTimeInterval(-30)
        ))
        let run = AgentRunRecord(id: runID, conversationID: conversationID, kind: .parent,
            parentRunID: nil, state: .preparing, endReason: nil, recoveryAction: nil,
            suspendReason: nil, triggerMessageID: triggerMessageID, responseMessageID: nil, retryOfRunID: nil,
            requestConfigSeed: requestConfigSeed, executionSnapshot: nil,
            createdAt: createdAt, updatedAt: createdAt, activeSlot: nil)
        try store.commitUserTurnAndCreateParentRun(SendCommit(
            conversation: ConversationRecord(id: conversationID, title: "", createdAt: createdAt,
                updatedAt: createdAt, userActiveAt: createdAt, pinned: false, lifecycle: .visible),
            message: MessageRecord(id: triggerMessageID, conversationID: conversationID,
                role: .user, sequence: 0, createdAt: createdAt),
            parts: [MessagePartRecord(id: "auth-card-ui-trigger-part", messageID: triggerMessageID,
                sequence: 0, kind: .text, state: .completed,
                payload: PersistenceStore.encodeTextPayload(.init(text: "Authentication refresh UI fixture")))],
            run: run
        ))
        try store.completeExecutionSnapshot(runID: runID, encodedSnapshot: executionSnapshot, at: createdAt)
        let attempt = AgentStepRecord(
            stepID: "auth-card-ui-step",
            runID: runID,
            sequence: 0,
            attempt: 1,
            createdAt: credentialFailureAt.addingTimeInterval(-10)
        )
        try store.recordStep(attempt)
        try store.markProviderStepStarted(attempt.attemptIdentity,
            at: credentialFailureAt.addingTimeInterval(-5))
        try store.transitionRun(id: runID, expectedState: .preparing, to: .requestingModel,
            at: credentialFailureAt.addingTimeInterval(-5))
        try store.suspendRunForCredentialFailure(
            runID: runID,
            expectedState: .requestingModel,
            attemptIdentity: attempt.attemptIdentity,
            source: .providerHTTP401,
            at: credentialFailureAt
        )
    }

    static func makeStore() throws -> PersistenceStore {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        try store.database.write { db in
            for index in 0..<12 {
                let date = Date(timeIntervalSince1970: Double(index))
                try ConversationRecord(id: "preview-ui-\(index)", title: "Workspace conversation \(index)",
                    createdAt: date, updatedAt: date, userActiveAt: date, pinned: false, lifecycle: .visible).insert(db)
            }
            let deep = ProcessInfo.processInfo.environment["ZEN_PREVIEW_DEEP_READING_UI_TEST"] == "1"
            let target = deep ? 120 : 10
            for index in 0..<(deep ? 240 : 20) {
                let date = Date(timeIntervalSince1970: Double(index + 100))
                let userID = "preview-reading-user-\(index)"
                let assistantID = "preview-reading-assistant-\(index)"
                for (id, role, sequence, text) in [
                    (userID, MessageRole.user, index * 2, "User prompt \(index)"),
                    (assistantID, MessageRole.assistant, index * 2 + 1,
                        index == target ? "PREVIEW_READING_ANCHOR_\(target)" :
                            (deep ? Array(repeating: "Assistant response \(index)", count: 4).joined(separator: "\n") : "Assistant response \(index)"))
                ] {
                    try MessageRecord(id: id, conversationID: "preview-ui-11", role: role,
                        sequence: sequence, createdAt: date).insert(db)
                    try MessagePartRecord(id: "part-\(id)", messageID: id, sequence: 0,
                        kind: .text, state: .completed,
                        payload: PersistenceStore.encodeTextPayload(.init(text: text))).insert(db)
                }
                try AgentRunRecord(id: "preview-reading-run-\(index)", conversationID: "preview-ui-11",
                    kind: .parent, parentRunID: nil, state: .completed, endReason: .completed,
                    recoveryAction: nil, suspendReason: nil, triggerMessageID: userID,
                    responseMessageID: assistantID, retryOfRunID: nil,
                    requestConfigSeed: RequestConfigSeed(providerInstanceID: ProviderInstanceID(rawValue: "preview-unavailable-instance"),
                        modelID: ModelID(rawValue: "preview-model"), providerConfigRevision: .initial,
                        credentialBinding: CredentialBindingSnapshot(reference: CredentialReference(id: "preview-missing-credential"), generation: 1),
                        resolvedEndpoint: URL(string: "https://preview.invalid")!),
                    executionSnapshot: nil, createdAt: date, updatedAt: date, activeSlot: nil).insert(db)
            }
        }
        if ProcessInfo.processInfo.environment["ZEN_RECENT_SPLIT_FAILURE_UI_TEST"] == "1" {
            // A real persisted decoding failure, while bounded Recent summaries
            // remain readable. Only this native regression seeds the extra Run.
            try store.database.write { db in
                for index in 0..<24 {
                    let date = Date(timeIntervalSince1970: Double(-index - 1))
                    try ConversationRecord(id: "recent-older-\(index)", title: "Older Recent conversation \(index)",
                        createdAt: date, updatedAt: date, userActiveAt: date, pinned: false, lifecycle: .visible).insert(db)
                }
                var run = try AgentRunRecord.fetchOne(db, key: "preview-reading-run-0")!
                run.id = "recent-split-failure-run"
                run.conversationID = "preview-ui-9"
                run.triggerMessageID = nil
                run.responseMessageID = nil
                try run.insert(db)
                try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                    arguments: ["invalid-recent-split-state", run.id])
            }
        }
        return store
    }

    static func restoreRecentSplitFailure(in store: PersistenceStore) throws {
        try store.database.write { db in
            try db.execute(sql: "UPDATE agentRun SET state = ? WHERE id = ?",
                arguments: [RunState.completed.rawValue, "recent-split-failure-run"])
        }
    }
}
#endif
