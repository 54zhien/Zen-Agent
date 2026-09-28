import Foundation

struct ConversationSummaryCursor: Equatable, Sendable {
    let pinned: Bool
    let userActiveAt: Date
    let id: String
}

struct ConversationSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let excerpt: String
    let pinned: Bool
    let userActiveAt: Date
    let contentUnavailable: Bool
    let runProjection: RunProjection?
    let providerInstanceID: ProviderInstanceID?
    let modelID: ModelID?
    let providerName: String?

    var cursor: ConversationSummaryCursor {
        ConversationSummaryCursor(pinned: pinned, userActiveAt: userActiveAt, id: id)
    }
}

struct ConversationSummaryPage: Equatable, Sendable {
    let items: [ConversationSummary]
    let nextCursor: ConversationSummaryCursor?
}

extension PersistenceStore {
    // Temporary runnable capability scaffold. These APIs still exhibit the old
    // whole-list read until the cursor/window/disclosure tests obtain real RED.
    func conversationSummaryPage(limit: Int = 50,
                                 after cursor: ConversationSummaryCursor? = nil) throws -> ConversationSummaryPage {
        let rows = try visibleConversations().sorted(by: Self.summaryOrder)
        return ConversationSummaryPage(items: rows.map(Self.summaryScaffold), nextCursor: nil)
    }

    func conversationSummaryWindow(ids: [String]) throws -> [ConversationSummary] {
        try visibleConversations().sorted(by: Self.summaryOrder)
            .filter { ids.contains($0.id) }.map(Self.summaryScaffold)
    }

    private static func summaryOrder(_ left: ConversationRecord, _ right: ConversationRecord) -> Bool {
        if left.pinned != right.pinned { return left.pinned }
        if left.userActiveAt != right.userActiveAt { return left.userActiveAt > right.userActiveAt }
        return left.id < right.id
    }

    private static func summaryScaffold(_ row: ConversationRecord) -> ConversationSummary {
        ConversationSummary(id: row.id, title: row.title, excerpt: "", pinned: row.pinned,
            userActiveAt: row.userActiveAt, contentUnavailable: false, runProjection: nil,
            providerInstanceID: nil, modelID: nil, providerName: nil)
    }
}
