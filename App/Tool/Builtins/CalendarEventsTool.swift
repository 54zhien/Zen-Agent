import Foundation

struct CalendarEventQuery: Sendable, Equatable {
    let startDate: Date
    let endDate: Date
}

struct CalendarEventSummary: Sendable, Equatable {
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
}

protocol CalendarEventsGateway: Sendable {
    func authorizationState() async -> ToolSystemPermissionState
    func requestFullAccess() async throws
    func events(in query: CalendarEventQuery) async throws -> [CalendarEventSummary]
}

struct CalendarEventsTool: ToolSystemPermissionProviding {
    static let toolID = "calendar_events"
    static let maximumEvents = 50

    let descriptor: ToolDescriptor
    private let gateway: any CalendarEventsGateway

    init(gateway: any CalendarEventsGateway = EventKitCalendarGateway()) {
        self.gateway = gateway
        self.descriptor = ToolDescriptor(
            id: Self.toolID,
            displayName: "Calendar Events",
            description: "Read event summaries from all calendars within an explicit date range. This tool never creates, edits, or deletes events.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "startDate": .object(["type": .string("string"), "format": .string("date-time")]),
                    "endDate": .object(["type": .string("string"), "format": .string("date-time")]),
                ]),
                "required": .array([.string("startDate"), .string("endDate")]),
                "additionalProperties": .bool(false),
            ]),
            revision: "1",
            sideEffect: .none,
            approvalRequirement: .required,
            actions: [ToolPolicyActionMetadata(
                toolID: Self.toolID,
                actionID: "read",
                descriptorRevision: "1",
                risk: .high,
                allowsAutomaticApproval: false,
                allowsConversationGrant: false,
                resourceRequirement: .target,
                egressRequirement: .providerRequiringApproval
            )]
        )
    }

    var systemPermissionDescription: String {
        "iOS 完全访问日历权限包含读取和写入能力。Zen Agent 的 Calendar 工具只读取事件，不会创建、修改或删除；查询结果会进入本次 Run 的模型请求，实际 Provider endpoint 显示在上方审批说明中。继续只会请求 iOS 系统权限，不会额外授予工具权限。"
    }

    func prepare(callID: String, argumentsJSON: String) throws -> ToolExecutionIntent {
        _ = callID
        throw ToolIntentFailure.preparationFailed
    }

    func prepare(
        callID: String,
        argumentsJSON: String,
        context: ToolPreparationContext
    ) throws -> ToolExecutionIntent {
        _ = callID
        let query = try parseQuery(argumentsJSON)
        let start = Self.iso8601.string(from: query.startDate)
        let end = Self.iso8601.string(from: query.endDate)
        let target = Self.targetIdentity(start: start, end: end)
        let normalizedArguments = try ToolArgumentJSON.normalizedObject([
            "startDate": start,
            "endDate": end,
        ])
        return try ToolIntentCodec.freeze(
            descriptor: descriptor,
            actionID: "read",
            normalizedArgumentsJSON: normalizedArguments,
            resource: .target(target),
            destination: context.destination,
            approvalDisclosure: ToolApprovalDisclosure(
                toolDisplayName: descriptor.displayName,
                action: "只读查询日历事件",
                targetDescription: "全部日历 · \(start) 至 \(end) · 最多返回 \(Self.maximumEvents) 条",
                keyImpact: "iOS 完全访问权限包含读取和写入能力；本工具只读取，不会创建、修改或删除事件。查询结果会进入模型请求并发送到本次 Run 冻结的 Provider endpoint：\(context.requestConfigSeed.endpoint.absoluteString)"
            )
        )
    }

    func validateDependencies(_ intent: ToolExecutionIntent, context: ToolPreparationContext) throws {
        _ = try query(from: intent)
        guard intent.destinationScope == context.destination else {
            throw ToolIntentFailure.dependenciesChanged
        }
    }

    func validateDependencies(_ intent: ToolExecutionIntent) throws {
        _ = try query(from: intent)
    }

    func execute(_ intent: ToolExecutionIntent, idempotencyKey: String) async throws -> ToolExecutionResult {
        _ = idempotencyKey
        let query = try query(from: intent)
        try Task.checkCancellation()
        let status = await gateway.authorizationState()
        try Task.checkCancellation()
        guard status == .authorized else { throw ToolSystemPermissionError.denied }

        let events = try await gateway.events(in: query)
        try Task.checkCancellation()
        let ordered = events.sorted(by: Self.precedes)
        let returned = ordered.prefix(Self.maximumEvents).map { event in
            CalendarEventPayload(
                title: event.title,
                startDate: Self.iso8601.string(from: event.startDate),
                endDate: Self.iso8601.string(from: event.endDate),
                isAllDay: event.isAllDay,
                location: event.location
            )
        }
        let payload = CalendarEventsPayload(
            startDate: Self.iso8601.string(from: query.startDate),
            endDate: Self.iso8601.string(from: query.endDate),
            events: Array(returned),
            truncated: ordered.count > Self.maximumEvents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ToolExecutionError.invalidArguments
        }
        return ToolExecutionResult(content: content)
    }

    func systemPermissionState(for intent: ToolExecutionIntent) async throws -> ToolSystemPermissionState {
        _ = try query(from: intent)
        return await gateway.authorizationState()
    }

    func requestSystemPermission(for intent: ToolExecutionIntent) async throws {
        _ = try query(from: intent)
        try await gateway.requestFullAccess()
    }

    func systemPermissionStateForSettings() async throws -> ToolSystemPermissionState? {
        await gateway.authorizationState()
    }

    private func query(from intent: ToolExecutionIntent) throws -> CalendarEventQuery {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        let query = try parseQuery(intent.normalizedArgumentsJSON)
        let start = Self.iso8601.string(from: query.startDate)
        let end = Self.iso8601.string(from: query.endDate)
        guard case .target(let target) = intent.resourceScope,
              ToolPolicyIdentity.equals(target, Self.targetIdentity(start: start, end: end)) else {
            throw ToolIntentFailure.invalidScope
        }
        return query
    }

    private func parseQuery(_ argumentsJSON: String) throws -> CalendarEventQuery {
        let object = try ToolArgumentJSON.object(from: argumentsJSON)
        guard object.count == 2,
              let startString = object["startDate"] as? String,
              let endString = object["endDate"] as? String,
              let startDate = Self.parseISO8601(startString),
              let endDate = Self.parseISO8601(endString),
              endDate > startDate else {
            throw ToolExecutionError.invalidArguments
        }
        return CalendarEventQuery(startDate: startDate, endDate: endDate)
    }

    private static func targetIdentity(start: String, end: String) -> String {
        "all-calendars:\(start)/\(end)"
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static var iso8601: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func precedes(_ lhs: CalendarEventSummary, _ rhs: CalendarEventSummary) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
        return lhs.title < rhs.title
    }
}

private struct CalendarEventsPayload: Encodable {
    let startDate: String
    let endDate: String
    let events: [CalendarEventPayload]
    let truncated: Bool
}

private struct CalendarEventPayload: Encodable {
    let title: String
    let startDate: String
    let endDate: String
    let isAllDay: Bool
    let location: String?
}
