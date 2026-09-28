import Foundation
import GRDB

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
    func conversationSummaryPage(limit: Int = 50,
                                 after cursor: ConversationSummaryCursor? = nil) throws -> ConversationSummaryPage {
        let count = min(50, max(1, limit))
        var predicate = "lifecycle = 'visible'"
        var arguments = StatementArguments()
        if let cursor {
            predicate += " AND (pinned < ? OR (pinned = ? AND userActiveAt < ?) OR (pinned = ? AND userActiveAt = ? AND id > ?))"
            arguments = [cursor.pinned, cursor.pinned, cursor.userActiveAt,
                         cursor.pinned, cursor.userActiveAt, cursor.id]
        }
        let rows = try summaryRows(predicate: predicate, limit: count + 1, arguments: arguments)
        let items = Array(rows.prefix(count))
        return ConversationSummaryPage(items: items,
            nextCursor: rows.count > count ? items.last?.cursor : nil)
    }

    func conversationSummaryWindow(ids: [String]) throws -> [ConversationSummary] {
        var unique: [String] = []
        for id in ids where !unique.contains(id) {
            unique.append(id)
            if unique.count == 4 { break }
        }
        guard !unique.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let rows = try summaryRows(predicate: "lifecycle = 'visible' AND id IN (\(placeholders))",
            limit: 4, arguments: StatementArguments(unique))
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return unique.compactMap { byID[$0] }
    }

    private func summaryRows(predicate: String, limit: Int,
                             arguments: StatementArguments) throws -> [ConversationSummary] {
        // Materialize only bounded metadata before looking up any message body.
        // JSON validation guards decoding; reasoning and credential references never leave SQL.
        let sql = """
        WITH page AS MATERIALIZED (
            SELECT id, substr(title, 1, 512) AS storedTitle, pinned, userActiveAt
            FROM conversation
            WHERE \(predicate)
            ORDER BY pinned DESC, userActiveAt DESC, id ASC
            LIMIT \(limit)
        )
        SELECT c.*,
            r.id AS runID, r.state AS runState, r.endReason,
            CASE WHEN json_valid(r.requestConfigSeed)
                 THEN json_extract(r.requestConfigSeed, '$.providerInstanceID') END AS providerInstanceID,
            CASE WHEN json_valid(r.requestConfigSeed)
                 THEN json_extract(r.requestConfigSeed, '$.modelID') END AS modelID,
            substr(pi.displayName, 1, 128) AS providerName,
            CASE WHEN json_valid(u.payload)
                 THEN CASE WHEN json_type(u.payload, '$.text') = 'text'
                           THEN substr(json_extract(u.payload, '$.text'), 1, 512) END END AS firstPrompt,
            CASE WHEN json_valid(l.payload)
                 THEN CASE WHEN json_type(l.payload, '$.text') = 'text'
                           THEN substr(json_extract(l.payload, '$.text'), 1, 321) END END AS excerpt,
            CASE WHEN u.payload IS NULL THEN 0
                 WHEN NOT json_valid(u.payload) THEN 1
                 WHEN json_type(u.payload, '$.text') IS NOT 'text' THEN 1 ELSE 0 END AS firstUnavailable,
            CASE WHEN l.payload IS NULL THEN 0
                 WHEN NOT json_valid(l.payload) THEN 1
                 WHEN json_type(l.payload, '$.text') IS NOT 'text' THEN 1 ELSE 0 END AS latestUnavailable
        FROM page c
        LEFT JOIN agentRun r ON r.id = (
            SELECT id FROM agentRun
            WHERE conversationID = c.id AND kind = 'parent'
            ORDER BY createdAt DESC, id DESC LIMIT 1
        )
        LEFT JOIN providerInstance pi ON pi.id = CASE WHEN json_valid(r.requestConfigSeed)
            THEN json_extract(r.requestConfigSeed, '$.providerInstanceID') END
        LEFT JOIN messagePart u ON u.id = (
            SELECT p.id FROM message m JOIN messagePart p ON p.messageID = m.id
            WHERE m.conversationID = c.id AND m.role = 'user' AND p.kind = 'text'
              AND CASE WHEN NOT json_valid(p.payload) THEN 1
                       WHEN json_type(p.payload, '$.text') IS NOT 'text' THEN 1
                       ELSE length(trim(json_extract(p.payload, '$.text'),
                         char(9,10,11,12,13,32,133,160,5760,8192,8193,8194,8195,8196,8197,
                              8198,8199,8200,8201,8202,8232,8233,8239,8287,12288))) > 0 END
            ORDER BY m.sequence ASC, m.id ASC, p.sequence ASC, p.id ASC LIMIT 1
        )
        LEFT JOIN messagePart l ON l.id = (
            SELECT p.id FROM message m JOIN messagePart p ON p.messageID = m.id
            WHERE m.conversationID = c.id AND m.role IN ('user', 'assistant') AND p.kind = 'text'
            ORDER BY m.sequence DESC, m.id DESC, p.sequence DESC, p.id DESC LIMIT 1
        )
        ORDER BY c.pinned DESC, c.userActiveAt DESC, c.id ASC
        """
        return try database.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                let runID: String? = row["runID"]
                var projection: RunProjection?
                if let runID {
                    let rawState: String = row["runState"]
                    guard let state = RunState(rawValue: rawState) else {
                        throw PersistenceError.invalidTransition("Unreadable summary Run state")
                    }
                    let rawReason: String? = row["endReason"]
                    let reason = rawReason.flatMap(EndReason.init(rawValue:))
                    if rawReason != nil && reason == nil {
                        throw PersistenceError.invalidTransition("Unreadable summary Run end reason")
                    }
                    projection = RunProjection(runID: runID, state: state, endReason: reason)
                }
                let stored: String = row["storedTitle"]
                let prompt: String? = row["firstPrompt"]
                let normalized = Self.summaryText(stored)
                let fallback = Self.summaryText(prompt ?? "")
                let title = normalized.isEmpty ? (fallback.isEmpty ? "未命名会话" : fallback) : normalized
                let providerID: String? = row["providerInstanceID"]
                let modelID: String? = row["modelID"]
                return ConversationSummary(id: row["id"], title: Self.summaryClip(title, limit: 56),
                    excerpt: Self.summaryClip(Self.summaryText(row["excerpt"] as String? ?? ""), limit: 320),
                    pinned: row["pinned"], userActiveAt: row["userActiveAt"],
                    contentUnavailable: (row["firstUnavailable"] as Int) != 0 || (row["latestUnavailable"] as Int) != 0,
                    runProjection: projection, providerInstanceID: providerID.map(ProviderInstanceID.init(rawValue:)),
                    modelID: modelID.map(ModelID.init(rawValue:)), providerName: row["providerName"])
            }
        }
    }

    private static func summaryText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func summaryClip(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
