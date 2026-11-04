import Foundation
import EventKit
import Testing
@testable import ZenAgent

@Suite("Stage 11 Parent reminders query")
struct RemindersToolTests {
    private let startDate = "2026-07-01T00:00:00-07:00"
    private let endDate = "2026-07-02T00:00:00-07:00"
    private let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    @Test func approvalFreezesReadOnlyQueryTimeZoneAndProviderDestination() throws {
        let tool = RemindersTool(gateway: RemindersGatewayFake(), timeZone: timeZone)
        let context = Self.context()
        let intent = try tool.prepare(
            callID: "reminders-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: context
        )

        #expect(tool.descriptor.sideEffect == .none)
        #expect(tool.descriptor.approvalRequirement == .required)
        #expect(tool.descriptor.actions.count == 1)
        #expect(tool.descriptor.actions[0].allowsAutomaticApproval == false)
        #expect(tool.descriptor.actions[0].allowsConversationGrant == false)
        #expect(intent.destinationScope == context.destination)
        let normalizedArguments = try #require(
            JSONSerialization.jsonObject(with: Data(intent.normalizedArgumentsJSON.utf8)) as? [String: String]
        )
        #expect(normalizedArguments["interpretationTimeZone"] == timeZone.identifier)
        #expect(intent.approvalDisclosure?.action.contains("只读") == true)
        #expect(intent.approvalDisclosure?.targetDescription.contains("2026-07-01T") == true)
        #expect(intent.approvalDisclosure?.targetDescription.contains("2026-07-02T") == true)
        #expect(intent.approvalDisclosure?.targetDescription.contains("America/Los_Angeles") == true)
        #expect(intent.approvalDisclosure?.keyImpact.contains("写入能力") == true)
        #expect(intent.approvalDisclosure?.keyImpact.contains("只读") == true)
        #expect(intent.approvalDisclosure?.keyImpact.contains(context.requestConfigSeed.endpoint.absoluteString) == true)
    }

    @Test func remindersToolIsExcludedFromDelegatedRuns() throws {
        let reminders = RemindersTool(gateway: RemindersGatewayFake(), timeZone: timeZone)
        let parentRegistry = try ToolRegistry(tools: [reminders, CurrentDateTool()])
        let childRegistry = try parentRegistry.filteringExecutables {
            !DelegationRuntime.isParentOnlyTool($0.descriptor)
        }

        #expect(childRegistry.descriptor(id: RemindersTool.toolID) == nil)
        #expect(childRegistry.descriptor(id: CurrentDateTool.toolID) != nil)
    }

    @Test func queryRejectsReversedRange() {
        let tool = RemindersTool(gateway: RemindersGatewayFake(), timeZone: timeZone)

        #expect(throws: ToolExecutionError.invalidArguments) {
            try tool.prepare(
                callID: "reversed",
                argumentsJSON: Self.arguments(start: endDate, end: startDate),
                context: Self.context()
            )
        }
    }

    @Test func queryReturnsOnlyBoundedIncompleteDueSummariesAndPreservesFloatingAllDay() async throws {
        let summaries = [
            Self.summary("timed", month: 7, day: 1, hour: 9, minute: 30, timeZoneIdentifier: "America/New_York"),
            Self.summary("floating all-day", day: 1),
            Self.summary("before range", month: 6, day: 30, hour: 23, minute: 59, timeZoneIdentifier: "America/Los_Angeles"),
            Self.summary("end boundary", day: 2),
        ]
        let gateway = RemindersGatewayFake(status: .authorized, reminders: summaries)
        let tool = RemindersTool(gateway: gateway, timeZone: timeZone)
        let intent = try tool.prepare(
            callID: "reminders-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: Self.context()
        )

        let result = try await tool.execute(intent, idempotencyKey: "reminders-query")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        let reminders = try #require(payload["reminders"] as? [[String: Any]])

        #expect(reminders.count == 2)
        #expect(reminders.first?["title"] as? String == "floating all-day")
        #expect(reminders.last?["title"] as? String == "timed")
        let floatingDue = try #require(reminders.first?["dueDate"] as? [String: Any])
        #expect(floatingDue["isFloating"] as? Bool == true)
        #expect(floatingDue["isAllDay"] as? Bool == true)
        #expect(floatingDue["timeZoneIdentifier"] == nil)
        let timedDue = try #require(reminders.last?["dueDate"] as? [String: Any])
        #expect(timedDue["isFloating"] as? Bool == false)
        #expect(timedDue["isAllDay"] as? Bool == false)
        #expect(timedDue["timeZoneIdentifier"] as? String == "America/New_York")
        #expect(Set(try #require(reminders.first).keys) == Set(["title", "listTitle", "dueDate"]))
        #expect(await gateway.queryCount == 1)
    }

    @Test func remindersAreNotReadWithoutFullAccess() async throws {
        let gateway = RemindersGatewayFake(status: .denied)
        let tool = RemindersTool(gateway: gateway, timeZone: timeZone)
        let intent = try tool.prepare(
            callID: "reminders-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: Self.context()
        )

        await #expect(throws: ToolSystemPermissionError.denied) {
            try await tool.execute(intent, idempotencyKey: "reminders-query")
        }
        #expect(await gateway.queryCount == 0)
    }

    @Test func writeOnlyAccessCanRequestFullRemindersAccessThroughPermissionDriver() async throws {
        let writeOnlyState = EventKitRemindersGateway.permissionState(for: .writeOnly)
        #expect(writeOnlyState == .notDetermined)
        let gateway = RemindersGatewayFake(status: writeOnlyState)
        let tool = RemindersTool(gateway: gateway, timeZone: timeZone)
        let intent = try tool.prepare(
            callID: "reminders-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: Self.context()
        )

        #expect(try await tool.systemPermissionState(for: intent) == writeOnlyState)
        try await tool.requestSystemPermission(for: intent)

        #expect(await gateway.permissionRequestCount == 1)
        #expect(await gateway.queryCount == 0)
    }

    @Test func cancellingTheAsyncQueryReturnsCancellationInsteadOfWaitingForCompletion() async throws {
        let gateway = RemindersGatewayFake(status: .authorized, waitsUntilCancelled: true)
        let tool = RemindersTool(gateway: gateway, timeZone: timeZone)
        let intent = try tool.prepare(
            callID: "reminders-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: Self.context()
        )
        let task = Task { try await tool.execute(intent, idempotencyKey: "reminders-query") }

        await gateway.waitUntilQueryStarts()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private static func summary(
        _ title: String,
        month: Int = 7,
        day: Int,
        hour: Int? = nil,
        minute: Int? = nil,
        timeZoneIdentifier: String? = nil
    ) -> ReminderSummary {
        ReminderSummary(
            title: title,
            listTitle: "Tasks",
            dueDate: ReminderDueDate(
                year: 2026,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: nil,
                timeZone: timeZoneIdentifier.map { TimeZone(identifier: $0)! },
                isFloating: timeZoneIdentifier == nil,
                isAllDay: hour == nil
            )
        )
    }

    private static func arguments(start: String, end: String) -> String {
        "{\"startDate\":\"\(start)\",\"endDate\":\"\(end)\"}"
    }

    private static func context() -> ToolPreparationContext {
        ToolPreparationContext(requestConfigSeed: RequestConfigSeed(
            providerInstanceID: ProviderInstanceID(rawValue: "reminders-test-instance"),
            modelID: ModelID(rawValue: "reminders-test-model"),
            providerConfigRevision: .initial,
            credentialBinding: CredentialBindingSnapshot(
                reference: CredentialReference(id: "reminders-test-key"),
                generation: 1
            ),
            resolvedEndpoint: URL(string: "https://api.example.test/v1/responses")!
        ))
    }
}

private actor RemindersGatewayFake: RemindersGateway {
    private let status: ToolSystemPermissionState
    private let reminders: [ReminderSummary]
    private let waitsUntilCancelled: Bool
    private var queryStarted = false
    private var queryStartWaiter: CheckedContinuation<Void, Never>?
    private var pendingQuery: CheckedContinuation<[ReminderSummary], Error>?
    private(set) var permissionRequestCount = 0
    private(set) var queryCount = 0

    init(
        status: ToolSystemPermissionState = .notDetermined,
        reminders: [ReminderSummary] = [],
        waitsUntilCancelled: Bool = false
    ) {
        self.status = status
        self.reminders = reminders
        self.waitsUntilCancelled = waitsUntilCancelled
    }

    func authorizationState() async -> ToolSystemPermissionState { status }

    func requestFullAccess() async throws { permissionRequestCount += 1 }

    func reminders(in query: RemindersQuery) async throws -> [ReminderSummary] {
        _ = query
        queryCount += 1
        queryStarted = true
        queryStartWaiter?.resume()
        queryStartWaiter = nil
        guard waitsUntilCancelled else { return reminders }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pendingQuery = $0 }
        } onCancel: {
            Task { await self.finishCancelledQuery() }
        }
    }

    func waitUntilQueryStarts() async {
        guard !queryStarted else { return }
        await withCheckedContinuation { queryStartWaiter = $0 }
    }

    private func finishCancelledQuery() {
        pendingQuery?.resume(throwing: CancellationError())
        pendingQuery = nil
    }
}
