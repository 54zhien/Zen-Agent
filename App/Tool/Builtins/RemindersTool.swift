import Foundation

struct RemindersQuery: Sendable, Equatable {
    let startDate: Date
    let endDate: Date
    let interpretationTimeZone: TimeZone
}

struct ReminderDueDate: Sendable, Equatable {
    let year: Int?
    let month: Int?
    let day: Int?
    let hour: Int?
    let minute: Int?
    let second: Int?
    let timeZone: TimeZone?
    let isFloating: Bool
    let isAllDay: Bool
}

struct ReminderSummary: Sendable, Equatable {
    let title: String
    let listTitle: String
    let dueDate: ReminderDueDate
}

protocol RemindersGateway: Sendable {
    func authorizationState() async -> ToolSystemPermissionState
    func requestFullAccess() async throws
    func reminders(in query: RemindersQuery) async throws -> [ReminderSummary]
}

struct RemindersTool: ToolSystemPermissionProviding {
    static let toolID = "reminders_query"
    static let maximumReminders = 50

    let descriptor: ToolDescriptor
    private let gateway: any RemindersGateway
    private let timeZone: TimeZone

    init(gateway: any RemindersGateway = EventKitRemindersGateway(), timeZone: TimeZone = .current) {
        self.gateway = gateway
        self.timeZone = timeZone
        self.descriptor = ToolDescriptor(
            id: Self.toolID,
            displayName: "Reminders",
            description: "Read incomplete reminders with due dates from all reminder lists within an explicit date range. This tool never creates, edits, or deletes reminders.",
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
        "iOS Reminders 完全访问权限包含读取和写入能力。Zen Agent 的 Reminders 工具只读取经你审批的未完成提醒及其截止日期，不会创建、修改或删除提醒。继续只请求 iOS 系统权限，不会额外授予工具权限。"
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
        let range = try parseRange(argumentsJSON)
        let start = Self.iso8601.string(from: range.startDate)
        let end = Self.iso8601.string(from: range.endDate)
        let zone = timeZone.identifier
        let normalizedArguments = try ToolArgumentJSON.normalizedObject([
            "startDate": start,
            "endDate": end,
            "interpretationTimeZone": zone,
        ])
        return try ToolIntentCodec.freeze(
            descriptor: descriptor,
            actionID: "read",
            normalizedArgumentsJSON: normalizedArguments,
            resource: .target(Self.targetIdentity(start: start, end: end, timeZone: zone)),
            destination: context.destination,
            approvalDisclosure: ToolApprovalDisclosure(
                toolDisplayName: descriptor.displayName,
                action: "只读查询未完成提醒及其截止日期",
                targetDescription: "全部提醒列表 · 未完成且带截止日期 · \(start) 至 \(end)（\(zone)，左闭右开）· 最多返回 \(Self.maximumReminders) 条",
                keyImpact: "iOS Reminders 完全访问权限包含读取和写入能力；本工具只读取提醒，不会创建、修改或删除。查询结果会进入模型请求并发送到本次 Run 冻结的 Provider endpoint：\(context.requestConfigSeed.endpoint.absoluteString)"
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

        let reminders = try await gateway.reminders(in: query)
        try Task.checkCancellation()
        let ordered = reminders.compactMap { reminder -> (ReminderSummary, Date)? in
            guard let dueDate = Self.interpretedDate(
                for: reminder.dueDate,
                interpretationTimeZone: query.interpretationTimeZone
            ), dueDate >= query.startDate, dueDate < query.endDate else {
                return nil
            }
            return (reminder, dueDate)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.0.title != rhs.0.title { return lhs.0.title < rhs.0.title }
            return lhs.0.listTitle < rhs.0.listTitle
        }
        let returned = ordered.prefix(Self.maximumReminders).map { item in
            let reminder = item.0
            return ReminderPayload(
                title: reminder.title,
                listTitle: reminder.listTitle,
                dueDate: ReminderDueDatePayload(reminder.dueDate)
            )
        }
        let payload = RemindersPayload(
            startDate: Self.iso8601.string(from: query.startDate),
            endDate: Self.iso8601.string(from: query.endDate),
            interpretationTimeZone: query.interpretationTimeZone.identifier,
            reminders: Array(returned),
            truncated: ordered.count > Self.maximumReminders
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

    private func query(from intent: ToolExecutionIntent) throws -> RemindersQuery {
        try ToolIntentCodec.validate(intent, descriptor: descriptor)
        let query = try parseFrozenQuery(intent.normalizedArgumentsJSON)
        guard case .target(let target) = intent.resourceScope,
              ToolPolicyIdentity.equals(
                target,
                Self.targetIdentity(
                    start: Self.iso8601.string(from: query.startDate),
                    end: Self.iso8601.string(from: query.endDate),
                    timeZone: query.interpretationTimeZone.identifier
                )
              ) else {
            throw ToolIntentFailure.invalidScope
        }
        return query
    }

    private func parseRange(_ argumentsJSON: String) throws -> (startDate: Date, endDate: Date) {
        let object = try ToolArgumentJSON.object(from: argumentsJSON)
        guard object.count == 2,
              let startString = object["startDate"] as? String,
              let endString = object["endDate"] as? String,
              let startDate = Self.parseISO8601(startString),
              let endDate = Self.parseISO8601(endString),
              endDate > startDate else {
            throw ToolExecutionError.invalidArguments
        }
        return (startDate, endDate)
    }

    private func parseFrozenQuery(_ argumentsJSON: String) throws -> RemindersQuery {
        let object = try ToolArgumentJSON.object(from: argumentsJSON)
        guard object.count == 3,
              let startString = object["startDate"] as? String,
              let endString = object["endDate"] as? String,
              let zoneIdentifier = object["interpretationTimeZone"] as? String,
              let startDate = Self.parseISO8601(startString),
              let endDate = Self.parseISO8601(endString),
              endDate > startDate,
              let zone = TimeZone(identifier: zoneIdentifier),
              zone.identifier == timeZone.identifier else {
            throw ToolExecutionError.invalidArguments
        }
        return RemindersQuery(
            startDate: startDate,
            endDate: endDate,
            interpretationTimeZone: zone
        )
    }

    private static func interpretedDate(
        for dueDate: ReminderDueDate,
        interpretationTimeZone: TimeZone
    ) -> Date? {
        guard let year = dueDate.year, let month = dueDate.month, let day = dueDate.day else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dueDate.timeZone ?? interpretationTimeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = dueDate.hour
        components.minute = dueDate.minute
        components.second = dueDate.second
        return calendar.date(from: components)
    }

    private static func targetIdentity(start: String, end: String, timeZone: String) -> String {
        "all-reminder-lists-incomplete-due:\(start)/\(end)/interpretation-time-zone:\(timeZone)"
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
}

private struct RemindersPayload: Encodable {
    let startDate: String
    let endDate: String
    let interpretationTimeZone: String
    let reminders: [ReminderPayload]
    let truncated: Bool
}

private struct ReminderPayload: Encodable {
    let title: String
    let listTitle: String
    let dueDate: ReminderDueDatePayload
}

private struct ReminderDueDatePayload: Encodable {
    let year: Int?
    let month: Int?
    let day: Int?
    let hour: Int?
    let minute: Int?
    let second: Int?
    let timeZoneIdentifier: String?
    let isFloating: Bool
    let isAllDay: Bool

    init(_ dueDate: ReminderDueDate) {
        year = dueDate.year
        month = dueDate.month
        day = dueDate.day
        hour = dueDate.hour
        minute = dueDate.minute
        second = dueDate.second
        timeZoneIdentifier = dueDate.timeZone?.identifier
        isFloating = dueDate.isFloating
        isAllDay = dueDate.isAllDay
    }
}
