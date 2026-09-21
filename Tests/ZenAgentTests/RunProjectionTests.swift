import Foundation
import Testing

@testable import ZenAgent

@Suite("Run projection")
struct RunProjectionTests {

    @Test("derives controls from the run state")
    func derivesControlsFromState() {
        let streaming = RunProjection(runID: "r1", state: .streaming)
        #expect(streaming.isActive)
        #expect(streaming.canStop)
        #expect(!streaming.isWaitingForApproval)
        #expect(!streaming.isSuspended)

        let stopping = RunProjection(runID: "r1", state: .stopping)
        #expect(stopping.isActive)
        #expect(!stopping.canStop)

        let waiting = RunProjection(runID: "r1", state: .waitingForApproval)
        #expect(waiting.isActive)
        #expect(waiting.canStop)
        #expect(waiting.isWaitingForApproval)
        #expect(!waiting.isSuspended)

        let suspended = RunProjection(runID: "r1", state: .suspended)
        #expect(suspended.isActive)
        #expect(suspended.canStop)
        #expect(!suspended.isWaitingForApproval)
        #expect(suspended.isSuspended)

        let completed = RunProjection(runID: "r1", state: .completed)
        #expect(!completed.isActive)
        #expect(!completed.canStop)
    }

    @Test("consumes AgentEvent state changes without reading provider DTOs")
    func consumesAgentEvents() {
        var projection = RunProjection(runID: "r1", state: .preparing)

        projection.apply(.runStateChanged(runID: "r1", state: .requestingModel))
        #expect(projection.state == .requestingModel)

        projection.apply(.messagePartDelta(runID: "r1", partID: "p1", delta: "hello"))
        #expect(projection.state == .requestingModel)

        projection.apply(.approvalRequired(runID: "r1", toolCallID: "t1"))
        #expect(projection.state == .requestingModel)
        #expect(!projection.isWaitingForApproval)

        projection.apply(.runStateChanged(runID: "r1", state: .waitingForApproval))
        #expect(projection.state == .waitingForApproval)
        #expect(projection.isWaitingForApproval)

        projection.apply(
            .runEnded(runID: "r1", state: .completed, endReason: .completed)
        )
        #expect(projection.state == .completed)
        #expect(!projection.isActive)
    }

    @Test("reduces an event stream into one projection")
    func reducesEvents() {
        let projection = RunProjection.from([
            .runAccepted(runID: "r1", conversationID: "c1"),
            .runStateChanged(runID: "r1", state: .streaming),
            .runEnded(runID: "r1", state: .failed, endReason: .providerFailed),
        ])

        #expect(projection?.runID == "r1")
        #expect(projection?.state == .failed)
        #expect(projection?.isActive == false)
    }
}
