import Foundation
import GRDB

extension PersistenceStore {
    func searchConversationSummaries(query: String, limit: Int = 50,
                                     after cursor: ConversationSummaryCursor? = nil) throws -> ConversationSummaryPage {
        try database.read { db in try searchConversationSummaries(in: db, query: query, limit: limit, after: cursor) }
    }

    func searchConversationSummariesAsync(query: String, limit: Int = 50,
                                          after cursor: ConversationSummaryCursor? = nil) async throws -> ConversationSummaryPage {
        try await database.readAsync { db in
            try self.searchConversationSummaries(in: db, query: query, limit: limit, after: cursor)
        }
    }

    private func searchConversationSummaries(in db: Database, query: String, limit: Int,
                                             after cursor: ConversationSummaryCursor?) throws -> ConversationSummaryPage {
        let needle = Self.summaryText(query)
        guard !needle.isEmpty else { return ConversationSummaryPage(items: [], nextCursor: nil) }
        let count = min(50, max(1, limit))
        // Filter before keyset LIMIT. The function matches exactly the bounded,
        // projected title, including malformed first-part fallback semantics.
        db.add(function: DatabaseFunction("zen_title_contains", argumentCount: 3, pure: true) { values in
            let title = Self.summaryTitle(stored: String.fromDatabaseValue(values[0]) ?? "",
                                          prompt: String.fromDatabaseValue(values[1]))
            let query = String.fromDatabaseValue(values[2]) ?? ""
            return title.range(of: query, options: .caseInsensitive) == nil ? 0 : 1
        })
        var predicate = """
        lifecycle = 'visible' AND zen_title_contains(substr(title, 1, 512), (
            SELECT CASE WHEN json_valid(first.payload)
                THEN CASE WHEN json_type(first.payload, '$.text') = 'text'
                    THEN substr(json_extract(first.payload, '$.text'), 1, 512) END END
            FROM messagePart first WHERE first.id = (
                \(Self.firstSummaryTextPartIDSQL(conversationID: "conversation.id"))
            )
        ), ?) = 1
        """
        var arguments: StatementArguments = [needle]
        if let cursor {
            predicate += " AND (pinned < ? OR (pinned = ? AND userActiveAt < ?) OR (pinned = ? AND userActiveAt = ? AND id > ?))"
            arguments += [cursor.pinned, cursor.pinned, cursor.userActiveAt,
                          cursor.pinned, cursor.userActiveAt, cursor.id]
        }
        let rows = try summaryRows(in: db, predicate: predicate, limit: count + 1, arguments: arguments)
        let items = Array(rows.prefix(count))
        return ConversationSummaryPage(items: items, nextCursor: rows.count > count ? items.last?.cursor : nil)
    }
}
