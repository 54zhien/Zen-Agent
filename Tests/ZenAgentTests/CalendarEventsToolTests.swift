import Foundation
import EventKit
import Testing
@testable import ZenAgent

@Suite("Stage 11 Parent calendar query")
struct CalendarEventsToolTests {
    private let startDate = "2026-10-01T00:00:00Z"
    private let endDate = "2026-10-02T00:00:00Z"

    @Test func approvalFreezesReadOnlyQueryAndProviderDestination() throws {
        let tool = CalendarEventsTool(gateway: CalendarEventsGatewayFake())
        let context = Self.context()
        let intent = try tool.prepare(
            callID: "calendar-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: context
        )

        #expect(tool.descriptor.sideEffect == .none)
        #expect(tool.descriptor.approvalRequirement == .required)
        #expect(tool.descriptor.actions.count == 1)
        #expect(tool.descriptor.actions[0].allowsAutomaticApproval == false)
        #expect(tool.descriptor.actions[0].allowsConversationGrant == false)
        #expect(intent.destinationScope == context.destination)
        #expect(intent.approvalDisclosure?.action.contains("只读") == true)
        #expect(intent.approvalDisclosure?.keyImpact.contains("创建、修改或删除") == true)
        #expect(intent.approvalDisclosure?.keyImpact.contains(context.requestConfigSeed.endpoint.absoluteString) == true)
    }

    @Test func parentOnlyCalendarToolIsExcludedFromDelegatedRuns() throws {
        let calendar = CalendarEventsTool(gateway: CalendarEventsGatewayFake())
        let parentRegistry = try ToolRegistry(tools: [calendar, CurrentDateTool()])
        let childRegistry = try parentRegistry.filteringExecutables {
            !DelegationRuntime.isParentOnlyTool($0.descriptor)
        }

        #expect(childRegistry.descriptor(id: CalendarEventsTool.toolID) == nil)
        #expect(childRegistry.descriptor(id: CurrentDateTool.toolID) != nil)
    }

    @Test func queryRejectsReversedRange() {
        let tool = CalendarEventsTool(gateway: CalendarEventsGatewayFake())

        #expect(throws: ToolExecutionError.invalidArguments) {
            try tool.prepare(callID: "reversed", argumentsJSON: Self.arguments(start: endDate, end: startDate), context: Self.context())
        }
    }

    @Test func queryReturnsChronologicalBoundedEventSummaries() async throws {
        let events = (0...CalendarEventsTool.maximumEvents).reversed().map { index in
            CalendarEventSummary(
                title: "event-\(index)",
                startDate: Date(timeIntervalSince1970: 1_790_812_800 + TimeInterval(index * 60)),
                endDate: Date(timeIntervalSince1970: 1_790_813_160 + TimeInterval(index * 60)),
                isAllDay: false,
                location: nil
            )
        }
        let gateway = CalendarEventsGatewayFake(status: .authorized, events: events)
        let tool = CalendarEventsTool(gateway: gateway)
        let intent = try tool.prepare(
            callID: "calendar-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: Self.context()
        )

        let result = try await tool.execute(intent, idempotencyKey: "calendar-query")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        let returnedEvents = try #require(payload["events"] as? [[String: Any]])

        let firstEvent = try #require(returnedEvents.first)
        let lastEvent = try #require(returnedEvents.last)

        #expect(returnedEvents.count == CalendarEventsTool.maximumEvents)
        #expect(payload["truncated"] as? Bool == true)
        #expect(firstEvent["title"] as? String == "event-0")
        #expect(firstEvent["startDate"] as? String == "2026-10-01T00:00:00.000Z")
        #expect(firstEvent["endDate"] as? String == "2026-10-01T00:06:00.000Z")
        #expect(firstEvent["isAllDay"] as? Bool == false)
        #expect(firstEvent["location"] == nil)
        #expect(Set(firstEvent.keys) == Set(["title", "startDate", "endDate", "isAllDay"]))
        #expect(lastEvent["title"] as? String == "event-49")
        #expect(lastEvent["startDate"] as? String == "2026-10-01T00:49:00.000Z")
        #expect(lastEvent["endDate"] as? String == "2026-10-01T00:55:00.000Z")
        #expect(await gateway.queryCount == 1)
    }

    @Test func eventsAreNotReadWithoutFullAccess() async throws {
        let gateway = CalendarEventsGatewayFake(status: .denied)
        let tool = CalendarEventsTool(gateway: gateway)
        let intent = try tool.prepare(
            callID: "calendar-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: Self.context()
        )

        await #expect(throws: ToolSystemPermissionError.denied) {
            try await tool.execute(intent, idempotencyKey: "calendar-query")
        }
        #expect(await gateway.queryCount == 0)
    }

    @Test func writeOnlyAccessCanRequestFullCalendarAccessThroughPermissionDriver() async throws {
        let writeOnlyState = EventKitCalendarGateway.permissionState(for: .writeOnly)
        #expect(writeOnlyState == .notDetermined)
        let gateway = CalendarEventsGatewayFake(status: writeOnlyState)
        let tool = CalendarEventsTool(gateway: gateway)
        let intent = try tool.prepare(
            callID: "calendar-query",
            argumentsJSON: Self.arguments(start: startDate, end: endDate),
            context: Self.context()
        )

        #expect(try await tool.systemPermissionState(for: intent) == writeOnlyState)
        try await tool.requestSystemPermission(for: intent)

        #expect(await gateway.permissionRequestCount == 1)
        #expect(await gateway.queryCount == 0)
    }

    private static func arguments(start: String, end: String) -> String {
        "{\"startDate\":\"\(start)\",\"endDate\":\"\(end)\"}"
    }

    private static func context() -> ToolPreparationContext {
        ToolPreparationContext(requestConfigSeed: RequestConfigSeed(
            providerInstanceID: ProviderInstanceID(rawValue: "calendar-test-instance"),
            modelID: ModelID(rawValue: "calendar-test-model"),
            providerConfigRevision: .initial,
            credentialBinding: CredentialBindingSnapshot(
                reference: CredentialReference(id: "calendar-test-key"),
                generation: 1
            ),
            resolvedEndpoint: URL(string: "https://api.example.test/v1/responses")!
        ))
    }
}

private actor CalendarEventsGatewayFake: CalendarEventsGateway {
    private let status: ToolSystemPermissionState
    private let events: [CalendarEventSummary]
    private(set) var permissionRequestCount = 0
    private(set) var queryCount = 0

    init(status: ToolSystemPermissionState = .notDetermined, events: [CalendarEventSummary] = []) {
        self.status = status
        self.events = events
    }

    func authorizationState() async -> ToolSystemPermissionState { status }

    func requestFullAccess() async throws { permissionRequestCount += 1 }

    func events(in query: CalendarEventQuery) async throws -> [CalendarEventSummary] {
        _ = query
        queryCount += 1
        return events
    }
}
