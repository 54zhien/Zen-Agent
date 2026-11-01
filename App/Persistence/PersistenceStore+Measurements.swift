import Foundation
import GRDB

struct Stage10ManualMeasurementContext: Sendable {
    let startedAt: Date
    let scenario: String
    let deviceHardwareModel: String?
    let deviceModelClass: String?
    let deviceEnvironment: String
    let operatingSystemName: String?
    let operatingSystemVersion: String?
    let appVersion: String?
    let appBuild: String?
    let sourceCommit: String?
    let providerHTTP429Responses: [[String: String]]
}

extension PersistenceStore {
    /// A local, content-free export consumed by the manual device measurement test.
    /// The run duration is the wall interval from Run creation to terminal transition;
    /// it includes preparation, tools and waiting as well as Provider time.
    func latestParentChildMeasurementJSON(
        context: Stage10ManualMeasurementContext,
        generatedAt: Date = Date()
    ) throws -> Data? {
        let candidateParentIDs = try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT parent.id FROM agentRun parent
                WHERE parent.kind = 'parent' AND parent.createdAt >= ? AND EXISTS (
                    SELECT 1 FROM delegatedChildRun delegation
                    JOIN agentRun child ON child.id = delegation.childRunID
                    WHERE child.kind = 'child' AND child.parentRunID = parent.id
                )
                ORDER BY parent.createdAt DESC, parent.id DESC
                """, arguments: [context.startedAt])
        }

        var parent: AgentRunRecord?
        var parentSnapshot: RunExecutionSnapshot?
        for parentID in candidateParentIDs {
            guard let candidate = try run(id: parentID),
                  let encodedSnapshot = candidate.executionSnapshot else { continue }
            let snapshot = try ExecutionSnapshotCodec.decode(encodedSnapshot)
            guard snapshot.delegation?.isHiddenDualChildProbe == true else { continue }
            parent = candidate
            parentSnapshot = snapshot
            break
        }
        guard let parent, let parentSnapshot else { return nil }

        let childIDs = try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT child.id FROM delegatedChildRun delegation
                JOIN agentRun child ON child.id = delegation.childRunID
                WHERE child.kind = 'child' AND child.parentRunID = ?
                ORDER BY child.createdAt, child.id
                """, arguments: [parent.id])
        }
        let children = try childIDs.compactMap { try run(id: $0) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parentJSON = try measurementJSON(
            for: parent,
            snapshot: parentSnapshot,
            formatter: formatter
        )
        let childrenJSON = try children.map { child in
            try measurementJSON(
                for: child,
                snapshot: try child.executionSnapshot.map { try ExecutionSnapshotCodec.decode($0) },
                formatter: formatter
            )
        }
        let providerHTTP429Observations: Any = context.providerHTTP429Responses.isEmpty
            ? NSNull()
            : context.providerHTTP429Responses.map { response in
                [
                    "status": 429,
                    "observedAt": nullableJSONValue(response["observedAt"]),
                    "retryAfterHeader": nullableJSONValue(response["retryAfterHeader"]),
                ] as [String: Any]
            }
        let childConcurrencyPeak = peakObservedChildConcurrency(children, through: generatedAt)
        let dualChildConcurrencySampleReached = (childConcurrencyPeak ?? 0) >= 2

        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "generatedAt": formatter.string(from: generatedAt),
                "measurementStartedAt": formatter.string(from: context.startedAt),
                "measurementMode": "manual",
                "scenario": context.scenario,
                "device": [
                    "hardwareModel": nullableJSONValue(context.deviceHardwareModel),
                    "modelClass": nullableJSONValue(context.deviceModelClass),
                    "environment": context.deviceEnvironment,
                ],
                "operatingSystem": [
                    "name": nullableJSONValue(context.operatingSystemName),
                    "version": nullableJSONValue(context.operatingSystemVersion),
                ],
                "build": [
                    "version": nullableJSONValue(context.appVersion),
                    "number": nullableJSONValue(context.appBuild),
                ],
                "commit": nullableJSONValue(context.sourceCommit),
                "commitProvenance": nullableJSONValue(
                    context.sourceCommit.map { _ in "operatorProvided" }
                ),
                "providerHTTP429Observations": providerHTTP429Observations,
                "providerHTTP429ObservationScope": "globalDeepSeekProviderTransportDuringManualMeasurementLaunch",
                "providerHTTP429Attribution": NSNull(),
                "providerHTTP429AttributionDefinition": "The HTTP transport exposes no Run, step, or attempt identity; these observations are not assigned to the selected Parent or any Child.",
                "reportedCostUSD": NSNull(),
                "reportedCostDefinition": "Actual provider billing is not queried; persisted token counts are not converted into estimated cost.",
                "providerConcurrencyLimit": NSNull(),
                "providerConcurrencyLimitDefinition": "The runtime does not capture a provider concurrency limit; actual 429 observations and Retry-After headers are reported separately.",
                "uiUpdateCost": NSNull(),
                "uiUpdateCostDefinition": "No direct UI update cost signposts are captured by this manual report.",
                "actualChildRunCount": childrenJSON.count,
                "dualChildLifecycleOverlapSampleStatus": dualChildConcurrencySampleReached
                    ? "reached"
                    : "notReached",
                "persistedChildLifecycleOverlapPeak": nullableJSONValue(childConcurrencyPeak),
                "childLifecycleOverlapMetricDefinition": "A dual-Child lifecycle-overlap sample is reached only when lifecycle intervals for two Child runs of this Parent overlap; this is not Provider request concurrency. Each interval starts at createdAt and ends at terminal updatedAt, or generatedAt while active.",
                "threeChildConcurrencySampleStatus": "notMeasured",
                "threeChildConcurrencySampleDefinition": "This manual fixed probe captures at most two Child runs; no three-Child measurement is performed.",
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
        snapshot: RunExecutionSnapshot?,
        formatter: ISO8601DateFormatter
    ) throws -> [String: Any] {
        guard let snapshot else {
            throw MeasurementReportError.missingExecutionSnapshot(runID: run.id)
        }
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
            "providerID": snapshot.providerID.rawValue,
            "modelID": run.requestConfigSeed.modelID.rawValue,
            "state": run.state.rawValue,
            "endReason": nullableJSONValue(run.endReason?.rawValue),
            "createdAt": formatter.string(from: run.createdAt),
            "terminalAt": terminalAt,
            "stopRequestedAt": nullableJSONValue(run.stopRequestedAt.map { formatter.string(from: $0) }),
            "createdToTerminalWallSeconds": terminalDuration,
            "stopToTerminalSeconds": nullableJSONValue(
                run.state.isTerminal
                    ? run.stopRequestedAt.map { run.updatedAt.timeIntervalSince($0) }
                    : nil
            ),
            "maxConcurrentChildren": nullableJSONValue(snapshot.delegation?.maxConcurrentChildren),
            "providerSteps": steps,
        ]
    }

    private func peakObservedChildConcurrency(
        _ children: [AgentRunRecord],
        through generatedAt: Date
    ) -> Int? {
        guard !children.isEmpty else { return nil }
        let events = children.flatMap { child -> [(Date, Int)] in
            let end = child.state.isTerminal ? child.updatedAt : generatedAt
            return [(child.createdAt, 1), (end, -1)]
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1 < $1.1
        }

        var active = 0
        var peak = 0
        for (_, delta) in events {
            active += delta
            peak = max(peak, active)
        }
        return peak
    }

    private func nullableJSONValue<Value>(_ value: Value?) -> Any {
        guard let value else { return NSNull() }
        return value
    }
}

private enum MeasurementReportError: Error {
    case missingExecutionSnapshot(runID: String)
}
