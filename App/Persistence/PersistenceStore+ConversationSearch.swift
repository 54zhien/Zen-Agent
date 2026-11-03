import Foundation
import GRDB

struct ConversationSearchResult: Equatable, Identifiable, Sendable {
    let summary: ConversationSummary
    let matchSnippet: String?
    let matchSnippetRanges: [Range<Int>]

    init(summary: ConversationSummary, matchSnippet: String?, matchSnippetRanges: [Range<Int>] = []) {
        self.summary = summary
        self.matchSnippet = matchSnippet
        self.matchSnippetRanges = matchSnippetRanges
    }

    var id: String { summary.id }
    var cursor: ConversationSummaryCursor { summary.cursor }
}

struct ConversationSearchPage: Equatable, Sendable {
    let items: [ConversationSearchResult]
    let nextCursor: ConversationSummaryCursor?
}

extension PersistenceStore {
    func searchConversationSummaries(query: String, limit: Int = 50,
                                     after cursor: ConversationSummaryCursor? = nil) throws -> ConversationSearchPage {
        try database.read { db in try searchConversationSummaries(in: db, query: query, limit: limit, after: cursor) }
    }

    func searchConversationSummariesAsync(query: String, limit: Int = 50,
                                          after cursor: ConversationSummaryCursor? = nil) async throws -> ConversationSearchPage {
        try await database.readAsync { db in
            try self.searchConversationSummaries(in: db, query: query, limit: limit, after: cursor)
        }
    }

    private func searchConversationSummaries(in db: Database, query: String, limit: Int,
                                             after cursor: ConversationSummaryCursor?) throws -> ConversationSearchPage {
        let needle = Self.summaryText(query)
        guard !needle.isEmpty else { return ConversationSearchPage(items: [], nextCursor: nil) }
        let count = min(50, max(1, limit))
        let pattern = FTS3Pattern(matchingPhrase: ConversationSearchText.normalized(needle))

        // Keep title matching identical to the existing UI contract. Body text uses
        // a phrase pattern so typed operators and punctuation are never FTS syntax.
        db.add(function: DatabaseFunction("zen_title_contains", argumentCount: 3, pure: true) { values in
            let title = Self.summaryTitle(stored: String.fromDatabaseValue(values[0]) ?? "",
                                          prompt: String.fromDatabaseValue(values[1]))
            let query = String.fromDatabaseValue(values[2]) ?? ""
            return title.range(of: query, options: .caseInsensitive) == nil ? 0 : 1
        })
        let titlePredicate = """
        zen_title_contains(substr(title, 1, 512), (
            SELECT CASE WHEN json_valid(first.payload)
                THEN CASE WHEN json_type(first.payload, '$.text') = 'text'
                    THEN substr(json_extract(first.payload, '$.text'), 1, 512) END END
            FROM messagePart first WHERE first.id = (
                \(Self.firstSummaryTextPartIDSQL(conversationID: "conversation.id"))
            )
        ), ?) = 1
        """
        var predicate = "lifecycle = 'visible' AND (\(titlePredicate)"
        var arguments: StatementArguments = [needle]
        if let pattern {
            predicate += " OR EXISTS (SELECT 1 FROM conversationSearchIndex WHERE conversationSearchIndex MATCH ('conversationKey:c' || lower(hex(conversation.id)) || ' text: ' || ?))"
            arguments += [pattern]
        }
        predicate += ")"
        if let cursor {
            predicate += " AND (pinned < ? OR (pinned = ? AND userActiveAt < ?) OR (pinned = ? AND userActiveAt = ? AND id > ?))"
            arguments += [cursor.pinned, cursor.pinned, cursor.userActiveAt,
                          cursor.pinned, cursor.userActiveAt, cursor.id]
        }

        let rows = try summaryRows(in: db, predicate: predicate, limit: count + 1, arguments: arguments)
        let summaries = Array(rows.prefix(count))
        let snippets: [String: ConversationSearchText.MatchSnippet]
        if let pattern {
            snippets = try searchMatchSnippets(in: db, pattern: pattern, conversationIDs: summaries.map(\.id))
        } else {
            snippets = [:]
        }
        let items = summaries.map { summary in
            let snippet = snippets[summary.id]
            return ConversationSearchResult(
                summary: summary,
                matchSnippet: snippet?.text,
                matchSnippetRanges: snippet?.ranges ?? []
            )
        }
        return ConversationSearchPage(items: items,
            nextCursor: rows.count > count ? items.last?.cursor : nil)
    }

    private func searchMatchSnippets(in db: Database, pattern: FTS3Pattern,
                                     conversationIDs: [String]) throws -> [String: ConversationSearchText.MatchSnippet] {
        var snippets: [String: ConversationSearchText.MatchSnippet] = [:]
        for conversationID in conversationIDs {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT snippet(conversationSearchIndex, ?, ?, ?, 4, 64) AS markedSnippet
                FROM conversationSearchIndex
                WHERE conversationSearchIndex MATCH (
                    'conversationKey:c' || lower(hex(?)) || ' text: ' || ?
                )
                ORDER BY docid
                LIMIT 1
                """, arguments: [
                    ConversationSearchText.startMarker,
                    ConversationSearchText.endMarker,
                    ConversationSearchText.ellipsisMarker,
                    conversationID,
                    pattern,
                ]) else { continue }

            let markedSnippet: String = row["markedSnippet"]
            snippets[conversationID] = ConversationSearchText.snippet(from: markedSnippet)
        }
        return snippets
    }
}
