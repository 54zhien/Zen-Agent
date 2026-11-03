import Testing
@testable import ZenAgent

@Suite("Stage 11 Parent reminders query")
struct RemindersToolTests {
    @Test func remindersToolIsParentOnly() {
        let descriptor = ToolDescriptor(
            id: "reminders_query",
            displayName: "Reminders",
            description: "Read incomplete reminders.",
            inputSchema: .object([:]),
            revision: "1",
            sideEffect: .none,
            approvalRequirement: .required
        )

        #expect(DelegationRuntime.isParentOnlyTool(descriptor))
    }
}
