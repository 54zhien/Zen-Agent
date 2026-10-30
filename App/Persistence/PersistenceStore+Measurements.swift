import Foundation
import GRDB

extension PersistenceStore {
    /// A local, content-free export consumed by the manual device measurement test.
    /// The run duration is the wall interval from Run creation to terminal transition;
    /// it includes preparation, tools and waiting as well as Provider time.
    func latestParentChildMeasurementJSON(generatedAt: Date = Date()) throws -> Data? {
        let selectedIDs = try database.read { db -> (String, [String])? in
            guard let parentID = try String.fetchOne(db, sql: """
                SELECT parent.id FROM agentRun parent
                WHERE parent.kind = 'parent' AND EXISTS (
                    SELECT 1 FROM delegatedChildRun delegation
                    JOIN agentRun child ON child.id = delegation.childRunID
                    WHERE child.kind = 'child' AND child.parentRunID = parent.id
                )
                ORDER BY parent.createdAt DESC, parent.id DESC
                LIMIT 1
                """) else { return nil }

            let childIDs = try String.fetchAll(db, sql: """
                SELECT child.id FROM delegatedChildRun delegation
                JOIN agentRun child ON child.id = delegation.childRunID
                WHERE child.kind = 'child' AND child.parentRunID = ?
                ORDER BY child.createdAt, child.id
                """, arguments: [parentID])
            return (parentID, childIDs)
        }
        guard let (parentID, childIDs) = selectedIDs,
              let parent = try run(id: parentID) else { return nil }
        let children = try childIDs.compactMap { try run(id: $0) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parentJSON = try measurementJSON(for: parent, formatter: formatter)
        let childrenJSON = try children.map { try measurementJSON(for: $0, formatter: formatter) }

        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "generatedAt": formatter.string(from: generatedAt),
                "runWallDurationDefinition": "createdAt to terminal updatedAt; includes preparation, tools, and waiting",
                "providerStepTimingDefinition": "providerStartedAt is immediately before stream invocation; providerFinishedAt is when Runtime receives finish",
                "parent": parentJSON,
                "children": childrenJSON,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func measurementJSON(
        for run: AgentRunRecord,
        formatter: ISO8601DateFormatter
    ) throws -> [String: Any] {
        let terminalAt = nullableJSONValue(
            run.state.isTerminal ? formatter.string(from: run.updatedAt) : nil
        )
        let terminalDuration = nullableJSONValue(
            run.state.isTerminal ? run.updatedAt.timeIntervalSince(run.createdAt) : nil
        )
        let steps: [[String: Any]] = try steps(inRun: run.id).map { step in
            [
                "stepID": step.stepID,
                "sequence": step.sequence,
                "attempt": step.attempt,
                "providerStartedAt": nullableJSONValue(step.providerStartedAt.map { formatter.string(from: $0) }),
                "providerFinishedAt": nullableJSONValue(step.providerFinishedAt.map { formatter.string(from: $0) }),
                "reportedPromptTokens": nullableJSONValue(step.reportedPromptTokens),
                "reportedCompletionTokens": nullableJSONValue(step.reportedCompletionTokens),
                "reportedTotalTokens": nullableJSONValue(step.reportedTotalTokens),
            ]
        }
        return [
            "runID": run.id,
            "parentRunID": nullableJSONValue(run.parentRunID),
            "kind": run.kind.rawValue,
            "state": run.state.rawValue,
            "endReason": nullableJSONValue(run.endReason?.rawValue),
            "createdAt": formatter.string(from: run.createdAt),
            "terminalAt": terminalAt,
            "stopRequestedAt": nullableJSONValue(run.stopRequestedAt.map { formatter.string(from: $0) }),
            "createdToTerminalWallSeconds": terminalDuration,
            "providerSteps": steps,
        ]
    }

    private func nullableJSONValue<Value>(_ value: Value?) -> Any {
        guard let value else { return NSNull() }
        return value
    }
}
