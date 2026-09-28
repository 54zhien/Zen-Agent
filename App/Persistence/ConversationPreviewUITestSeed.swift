#if DEBUG
import Foundation
import GRDB

enum ConversationPreviewUITestSeed {
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
        return store
    }
}
#endif
