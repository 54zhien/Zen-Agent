import Foundation

struct CurrentDateTool: ToolExecutable {
    static let toolID = "current_date"

    let descriptor: ToolDescriptor
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    init(
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.clock = clock
        self.timeZone = timeZone
        self.descriptor = ToolDescriptor(
            id: Self.toolID,
            displayName: "Current Date",
            description: "Returns the current date, time, and time zone.",
            inputSchema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
            ]),
            revision: "1",
            sideEffect: .none,
            approvalRequirement: .notRequired
        )
    }

    func prepare(
        callID: String,
        argumentsJSON: String
    ) throws -> ToolExecutionIntent {
        _ = callID
        try ToolArgumentJSON.requireEmptyObject(argumentsJSON)

        return ToolExecutionIntent(
            formatVersion: ToolExecutionIntent.currentFormatVersion,
            toolID: descriptor.id,
            descriptorRevision: descriptor.revision,
            normalizedArgumentsJSON: "{}",
            targetIdentity: nil,
            destinationIdentity: nil
        )
    }

    func execute(
        _ intent: ToolExecutionIntent,
        idempotencyKey: String
    ) async throws -> ToolExecutionResult {
        _ = idempotencyKey
        guard
            intent.formatVersion == ToolExecutionIntent.currentFormatVersion,
            intent.toolID == descriptor.id,
            intent.descriptorRevision == descriptor.revision,
            intent.normalizedArgumentsJSON == "{}",
            intent.targetIdentity == nil,
            intent.destinationIdentity == nil
        else {
            throw ToolExecutionError.invalidIntent
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"

        let date = formatter.string(from: clock())
        return ToolExecutionResult(
            content: "(date) (\(timeZone.identifier))"
        )
    }
}
