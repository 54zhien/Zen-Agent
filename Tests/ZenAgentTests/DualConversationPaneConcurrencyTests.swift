import Foundation
import GRDB
import Testing

@testable import ZenAgent

@Suite("Dual conversation pane concurrency")
@MainActor
struct DualConversationPaneConcurrencyTests {

    fileprivate static let conversationA = "dual-pane-conversation-a"
    fileprivate static let conversationB = "dual-pane-conversation-b"
    private static let streamPromptA = "stream prompt A"
    private static let streamPromptB = "stream prompt B"
    private static let approvalPromptA = "request the approved test tool"
    private static let completionPromptB = "finish while pane A waits"
    private static let continuationTextA = "A completed after approval"
    private static let completionTextB = "B completed independently"
    private static let firstTextA = String(repeating: "a", count: 1_024)
    private static let secondTextA = String(repeating: "x", count: 1_280)
    private static let firstTextB = String(repeating: "b", count: 1_024)
    private static let secondTextB = String(repeating: "y", count: 1_536)
    private static let sideEffectToolID = "stage2_side_effect"
    private static let approvalToolCallID = "dual-pane-approval-call-a"

    @Test
    func concurrentStreamingChangesOnlyOwningPane() async throws {
        let boxA = Stage2StreamBox()
        let boxB = Stage2StreamBox()
        let fallback = [ProviderStreamEvent.finish(.stop)]
        let harness = try DualConversationPaneHarness(
            scripts: [
                // Request 0 belongs to Run A; its first 1,024-byte text delta is held open.
                .holding(prefix: [.textDelta(Self.firstTextA)], box: boxA),
                // Request 1 belongs to Run B; its first 1,024-byte text delta is held open.
                .holding(prefix: [.textDelta(Self.firstTextB)], box: boxB),
                // Request 2 is a finite fallback so an accidental extra request cannot hang.
                .events(fallback),
            ],
            streamBoxes: [boxA, boxB]
        )

        harness.seedDistinctPaneState()
        let initialSnapshotB = try await harness.snapshot(
            pane: harness.paneB,
            viewport: harness.viewportB
        )
        var runA: String?
        var runB: String?

        do {
            runA = try await harness.startRun(
                conversationID: Self.conversationA,
                text: Self.streamPromptA
            )
            let startedA = try await harness.waitForDelivery(
                .partStarted(runID: try require(runA, "Run A id")),
                label: "Run A messagePartStarted consumption"
            )
            harness.markStreamObserved(boxA)
            #expect(startedA.ownerConversationID == Self.conversationA)
            let partIDA = try partID(from: startedA.event)

            let firstDeltaA = try await harness.waitForDelivery(
                .partDelta(runID: try require(runA, "Run A id"), text: Self.firstTextA),
                label: "Run A threshold messagePartDelta consumption"
            )
            #expect(firstDeltaA.ownerConversationID == Self.conversationA)
            expectLiveText(
                in: harness.paneA,
                partID: partIDA,
                expected: Self.firstTextA
            )
            let snapshotBAfterRunA = try await harness.snapshot(
                pane: harness.paneB,
                viewport: harness.viewportB
            )
            #expect(snapshotBAfterRunA == initialSnapshotB)

            let snapshotABeforeRunB = try await harness.snapshot(
                pane: harness.paneA,
                viewport: harness.viewportA
            )
            runB = try await harness.startRun(
                conversationID: Self.conversationB,
                text: Self.streamPromptB
            )
            let startedRunB = try require(runB, "Run B id")
            let startedB = try await harness.waitForDelivery(
                .partStarted(runID: startedRunB),
                label: "Run B messagePartStarted consumption"
            )
            harness.markStreamObserved(boxB)
            #expect(startedB.ownerConversationID == Self.conversationB)
            let partIDB = try partID(from: startedB.event)

            let firstDeltaB = try await harness.waitForDelivery(
                .partDelta(runID: startedRunB, text: Self.firstTextB),
                label: "Run B threshold messagePartDelta consumption"
            )
            #expect(firstDeltaB.ownerConversationID == Self.conversationB)
            expectLiveText(
                in: harness.paneB,
                partID: partIDB,
                expected: Self.firstTextB
            )
            #expect(Set(harness.paneB.liveStore.state.activeParts.values.map(\.runID)) == Set([startedRunB]))
            let snapshotAAfterRunB = try await harness.snapshot(
                pane: harness.paneA,
                viewport: harness.viewportA
            )
            #expect(snapshotAAfterRunB == snapshotABeforeRunB)

            let runARecord = try harness.store.run(id: try require(runA, "Run A id"))
            let runBRecord = try harness.store.run(id: try require(runB, "Run B id"))
            #expect(runARecord?.state == .streaming)
            #expect(runBRecord?.state == .streaming)
            #expect(runARecord?.state.isTerminal == false)
            #expect(runBRecord?.state.isTerminal == false)
            #expect(boxA.cancellations == 0)
            #expect(boxB.cancellations == 0)
            let requestsAtOverlap = try await harness.requestsSnapshot()
            #expect(requestsAtOverlap.count == 2)

            let snapshotBBeforeDeltaA = try await harness.snapshot(
                pane: harness.paneB,
                viewport: harness.viewportB
            )
            boxA.yieldLate(.textDelta(Self.secondTextA))
            let secondDeltaA = try await harness.waitForDelivery(
                .partDelta(runID: try require(runA, "Run A id"), text: Self.secondTextA),
                label: "Run A second messagePartDelta consumption"
            )
            #expect(secondDeltaA.ownerConversationID == Self.conversationA)
            expectLiveText(
                in: harness.paneA,
                partID: partIDA,
                expected: Self.firstTextA + Self.secondTextA,
                addedByteCount: Self.secondTextA.utf8.count
            )
            let snapshotBAfterDeltaA = try await harness.snapshot(
                pane: harness.paneB,
                viewport: harness.viewportB
            )
            #expect(snapshotBAfterDeltaA == snapshotBBeforeDeltaA)

            let snapshotABeforeDeltaB = try await harness.snapshot(
                pane: harness.paneA,
                viewport: harness.viewportA
            )
            boxB.yieldLate(.textDelta(Self.secondTextB))
            let secondDeltaB = try await harness.waitForDelivery(
                .partDelta(runID: try require(runB, "Run B id"), text: Self.secondTextB),
                label: "Run B second messagePartDelta consumption"
            )
            #expect(secondDeltaB.ownerConversationID == Self.conversationB)
            expectLiveText(
                in: harness.paneB,
                partID: partIDB,
                expected: Self.firstTextB + Self.secondTextB,
                addedByteCount: Self.secondTextB.utf8.count
            )
            let snapshotAAfterDeltaB = try await harness.snapshot(
                pane: harness.paneA,
                viewport: harness.viewportA
            )
            #expect(snapshotAAfterDeltaB == snapshotABeforeDeltaB)

            try await harness.stop(runID: try require(runA, "Run A id"))
            try await harness.stop(runID: try require(runB, "Run B id"))
            try await harness.waitForCancellation(of: boxA, label: "Run A provider cancellation")
            try await harness.waitForCancellation(of: boxB, label: "Run B provider cancellation")
            #expect(try harness.store.run(id: try require(runA, "Run A id"))?.state == .cancelled)
            #expect(try harness.store.run(id: try require(runB, "Run B id"))?.state == .cancelled)
            let finalRequests = try await harness.requestsSnapshot()
            #expect(finalRequests.count == 2)
        } catch {
            Issue.record("concurrent streaming scenario failed: \(String(reflecting: error))")
        }

        await harness.stopActiveRuns()
        do {
            let finalRequests = try await harness.requestsSnapshot()
            #expect(finalRequests.count == 2)
        } catch {
            Issue.record("could not verify final streaming request count: \(String(reflecting: error))")
        }
        let routingErrors = await harness.eventLog.errorsSnapshot()
        #expect(routingErrors.isEmpty, "event routing or Pane consumption errors: \(routingErrors)")
    }

    @Test
    func approvalInOnePaneDoesNotBlockOtherPaneCompletion() async throws {
        let sideEffectLedger = SideEffectLedger()
        let sideEffectTool = Stage2SideEffectTool(ledger: sideEffectLedger)
        let toolRegistry = try ToolRegistry(tools: [sideEffectTool])
        let harness = try DualConversationPaneHarness(
            scripts: [
                // Request 0 belongs to Run A and creates the registered, approval-required tool call.
                .events([
                    .toolCall(ProviderToolCall(
                        id: Self.approvalToolCallID,
                        index: 0,
                        name: Self.sideEffectToolID,
                        argumentsJSON: "{}"
                    )),
                    .finish(.toolCalls),
                ]),
                // Request 1 belongs to Run B and finishes while Run A remains gated.
                .events([.textDelta(Self.completionTextB), .finish(.stop)]),
                // Request 2 belongs to Run A after approval and completes its continuation.
                .events([.textDelta(Self.continuationTextA), .finish(.stop)]),
            ],
            toolRegistry: toolRegistry
        )

        #expect(sideEffectTool.descriptor.id == Self.sideEffectToolID)
        #expect(sideEffectTool.descriptor.approvalRequirement == .required)
        var runA: String?
        var runB: String?

        do {
            runA = try await harness.startRun(
                conversationID: Self.conversationA,
                text: Self.approvalPromptA
            )
            let startedA = try require(runA, "Run A id")
            let approvalDelivery = try await harness.waitForDelivery(
                .approvalRequired(
                    runID: startedA,
                    toolCallID: Self.approvalToolCallID
                ),
                label: "Run A approvalRequired consumption"
            )
            #expect(approvalDelivery.ownerConversationID == Self.conversationA)
            _ = try await harness.waitForDelivery(
                .runState(runID: startedA, state: .waitingForApproval),
                label: "Run A waitingForApproval state consumption"
            )

            let waitingRun = try harness.store.run(id: startedA)
            let waitingCall = try harness.store.toolCall(id: Self.approvalToolCallID)
            #expect(waitingRun?.state == .waitingForApproval)
            #expect(waitingCall?.state == .waitingForApproval)
            let projectionAWhileWaiting = try await harness.projection(
                conversationID: Self.conversationA
            )
            #expect(projectionAWhileWaiting?.runID == startedA)
            #expect(projectionAWhileWaiting?.state == .waitingForApproval)

            try await harness.refreshApprovals(in: harness.paneA)
            let approvalsA = try await harness.pendingApprovals(
                conversationID: Self.conversationA
            )
            #expect(approvalsA.map(\.toolCallID) == [Self.approvalToolCallID])
            #expect(harness.paneA.liveStore.state.pendingToolApprovals.map(\.toolCallID) == [Self.approvalToolCallID])
            #expect(harness.paneA.liveStore.state.pendingToolApprovals.allSatisfy {
                $0.conversationID == Self.conversationA
            })
            let pendingBWhileAWaits = try await harness.pendingApprovals(
                conversationID: Self.conversationB
            )
            #expect(pendingBWhileAWaits.isEmpty)
            #expect(harness.paneB.liveStore.state.pendingToolApprovals.isEmpty)
            #expect(!harness.paneB.liveStore.needsPendingToolApprovalReconciliation)

            runB = try await harness.startRun(
                conversationID: Self.conversationB,
                text: Self.completionPromptB
            )
            let startedB = try require(runB, "Run B id")
            let bDelta = try await harness.waitForDelivery(
                .partDelta(runID: startedB, text: Self.completionTextB),
                label: "Run B assistant text consumption"
            )
            #expect(bDelta.ownerConversationID == Self.conversationB)
            try await harness.waitForCompletion(runID: startedB)

            let completedRunB = try harness.store.run(id: startedB)
            let projectionB = try await harness.projection(conversationID: Self.conversationB)
            #expect(completedRunB?.state == .completed)
            #expect(projectionB?.runID == startedB)
            #expect(projectionB?.state == .completed)
            #expect(assistantTexts(in: harness.paneB.liveStore.state.timeline) == [Self.completionTextB])
            let pendingApprovalsBAfterCompletion = try await harness.pendingApprovals(
                conversationID: Self.conversationB
            )
            #expect(pendingApprovalsBAfterCompletion.isEmpty)
            #expect(harness.paneB.liveStore.state.pendingToolApprovals.isEmpty)

            let projectionAStillWaiting = try await harness.projection(
                conversationID: Self.conversationA
            )
            #expect(try harness.store.run(id: startedA)?.state == .waitingForApproval)
            #expect(projectionAStillWaiting?.state == .waitingForApproval)
            #expect(harness.paneA.liveStore.state.pendingToolApprovals.map(\.toolCallID) == [Self.approvalToolCallID])

            let snapshotBBeforeApproval = try await harness.snapshot(
                pane: harness.paneB,
                viewport: harness.viewportB
            )
            guard let approval = harness.paneA.liveStore.state.pendingToolApprovals.first(where: {
                $0.toolCallID == Self.approvalToolCallID
            }) else {
                throw DualPaneHarnessError.missingValue("Pane A approval card")
            }
            try await harness.resolveApproval(approval.request(for: .approveOnce))
            try await harness.refreshApprovals(in: harness.paneA)

            let remainingApprovalsA = try await harness.pendingApprovals(
                conversationID: Self.conversationA
            )
            #expect(!remainingApprovalsA.contains {
                $0.toolCallID == Self.approvalToolCallID
            })
            #expect(!harness.paneA.liveStore.state.pendingToolApprovals.contains {
                $0.toolCallID == Self.approvalToolCallID
            })

            try await harness.waitForCompletion(runID: startedA)
            #expect(try harness.store.toolCall(id: Self.approvalToolCallID)?.state == .succeeded)
            let completedRunA = try harness.store.run(id: startedA)
            let projectionACompleted = try await harness.projection(
                conversationID: Self.conversationA
            )
            #expect(completedRunA?.state == .completed)
            #expect(projectionACompleted?.runID == startedA)
            #expect(projectionACompleted?.state == .completed)

            // Completion is not used as the Pane-consumption barrier: wait for the
            // continuation delta itself after request 2 has been consumed by both Panes.
            let continuationDelta = try await harness.waitForDelivery(
                .partDelta(runID: startedA, text: Self.continuationTextA),
                label: "Run A request 2 continuation delta consumption"
            )
            #expect(continuationDelta.ownerConversationID == Self.conversationA)
            #expect(assistantTexts(in: harness.paneA.liveStore.state.timeline) == [Self.continuationTextA])
            let snapshotBAfterApprovalResolution = try await harness.snapshot(
                pane: harness.paneB,
                viewport: harness.viewportB
            )
            #expect(snapshotBAfterApprovalResolution == snapshotBBeforeApproval)

            let requests = try await harness.requestsSnapshot()
            #expect(requests.count == 3)
            if requests.count == 3 {
                #expect(requests[0].messages.first == .user(Self.approvalPromptA))
                #expect(requests[1].messages.first == .user(Self.completionPromptB))
                #expect(requests[2].messages.first == .user(Self.approvalPromptA))
                #expect(containsToolResult(
                    callID: Self.approvalToolCallID,
                    in: requests[2].messages
                ))
            }
        } catch {
            Issue.record("approval isolation scenario failed: \(String(reflecting: error))")
        }

        await harness.stopActiveRuns()
        do {
            let finalRequests = try await harness.requestsSnapshot()
            #expect(finalRequests.count == 3)
        } catch {
            Issue.record("could not verify final approval request count: \(String(reflecting: error))")
        }
        let routingErrors = await harness.eventLog.errorsSnapshot()
        #expect(routingErrors.isEmpty, "event routing or Pane consumption errors: \(routingErrors)")
    }

    @Test
    func bottomAnchorAndScrollReceiptsStayInOwningPane() async throws {
        let geometryA = ScrollGeometry(viewportHeight: 400, contentHeight: 1_200, offset: 300)
        let geometryB = ScrollGeometry(viewportHeight: 350, contentHeight: 1_600, offset: 245)
        let harness = try DualConversationPaneHarness(
            scripts: [.events([.finish(.stop)])],
            initialGeometryA: geometryA,
            initialGeometryB: geometryB
        )
        let runIDA = "bottom-anchor-run-a"
        let runIDB = "bottom-anchor-run-b"
        let turnTopBefore = 500.0
        let turnTopAfter = 540.0
        let resizedGeometryA = ScrollGeometry(
            viewportHeight: 300,
            contentHeight: 1_300,
            offset: geometryA.offset
        )

        do {
            harness.paneA.scrollBridge.userScrolled(
                geometry: geometryA,
                topVisibleTurn: (runID: runIDA, turnTop: turnTopBefore)
            )
            let readingAnchor = TurnAnchor(
                runID: runIDA,
                relativeViewportOffset: (turnTopBefore - geometryA.offset) / geometryA.viewportHeight
            )
            #expect(harness.paneA.readingPosition.mode == .reading(
                anchor: readingAnchor,
                pendingTurns: []
            ))

            harness.paneA.scrollBridge.beginHeightChange(
                geometry: geometryA,
                bottomReferenceTurn: (runID: runIDA, turnTop: turnTopBefore)
            )
            harness.viewportA.measureLayout(
                viewportHeight: resizedGeometryA.viewportHeight,
                contentHeight: resizedGeometryA.contentHeight
            )
            let capturedBottomAnchor = AnchorResolver.captureBottomAnchor(
                runID: runIDA,
                turnTop: turnTopBefore,
                geometry: geometryA
            )
            #expect(capturedBottomAnchor == BottomTurnAnchor(
                runID: runIDA,
                bottomEdgeFromTurnTop: geometryA.offset + geometryA.viewportHeight - turnTopBefore
            ))
            guard let capturedBottomAnchor else {
                throw DualPaneHarnessError.missingValue("A bottom anchor")
            }

            harness.paneA.scrollBridge.continueHeightChange(
                geometry: resizedGeometryA,
                turnTops: [runIDA: turnTopAfter]
            )
            let expectedUnclampedOffset = try require(
                AnchorResolver.restoreTargetFromBottomAnchor(
                    anchor: capturedBottomAnchor,
                    turnTop: turnTopAfter,
                    contentHeight: resizedGeometryA.contentHeight,
                    viewportHeight: resizedGeometryA.viewportHeight
                ),
                "restored bottom-anchor target"
            )
            let expectedOffset = min(
                max(0, expectedUnclampedOffset),
                max(0, resizedGeometryA.contentHeight - resizedGeometryA.viewportHeight)
            )
            let requestA = try require(harness.paneA.scrollRequest, "Pane A maintain-bottom-edge request")
            #expect(requestA.action == .maintainBottomEdge(targetOffset: expectedOffset))
            #expect(requestA.action == .maintainBottomEdge(targetOffset: 440))

            _ = harness.paneB.updateReading(.contentChanged(changedRunIDs: [runIDB]))
            let requestB = try require(harness.paneB.scrollRequest, "Pane B scroll-to-bottom request")
            #expect(requestB.action == .scrollToBottom)

            let snapshotBBeforeReceiptA = scrollSnapshot(
                pane: harness.paneB,
                viewport: harness.viewportB
            )
            let offsetABeforeReceipt = harness.viewportA.geometry.offset
            #expect(harness.viewportA.apply(
                requestA,
                to: harness.paneA,
                turnTops: [runIDA: turnTopAfter]
            ))
            #expect(harness.viewportA.geometry.offset != offsetABeforeReceipt)
            #expect(harness.viewportA.geometry.offset == expectedOffset)
            #expect(harness.paneA.scrollRequest == nil)
            #expect(scrollSnapshot(
                pane: harness.paneB,
                viewport: harness.viewportB
            ) == snapshotBBeforeReceiptA)

            let snapshotAAfterReceiptA = scrollSnapshot(
                pane: harness.paneA,
                viewport: harness.viewportA
            )
            let offsetBBeforeReceipt = harness.viewportB.geometry.offset
            #expect(harness.viewportB.apply(
                requestB,
                to: harness.paneB,
                turnTops: [:]
            ))
            #expect(harness.viewportB.geometry.offset != offsetBBeforeReceipt)
            #expect(harness.paneB.scrollRequest == nil)
            #expect(scrollSnapshot(
                pane: harness.paneA,
                viewport: harness.viewportA
            ) == snapshotAAfterReceiptA)
        } catch {
            Issue.record("bottom anchor receipt scenario failed: \(String(reflecting: error))")
        }

        await harness.stopActiveRuns()
        let routingErrors = await harness.eventLog.errorsSnapshot()
        #expect(routingErrors.isEmpty, "event routing or Pane consumption errors: \(routingErrors)")
    }

    private func require<Value>(
        _ value: Value?,
        _ label: String
    ) throws -> Value {
        guard let value else { throw DualPaneHarnessError.missingValue(label) }
        return value
    }

    private func partID(from event: AgentEvent) throws -> String {
        guard case .messagePartStarted(_, _, let partID, _) = event else {
            throw DualPaneHarnessError.unexpectedEvent("expected messagePartStarted; received \(event)")
        }
        return partID
    }

    private func assistantTexts(in timeline: ConversationTimelineProjection) -> [String] {
        timeline.turns.flatMap { turn -> [String] in
            turn.items.compactMap { item -> String? in
                guard case .assistantText(let text) = item else { return nil }
                return text
            }
        }
    }

    private func expectLiveText(
        in pane: ConversationPaneController,
        partID: String,
        expected: String,
        addedByteCount: Int? = nil
    ) {
        let visibleText = assistantTexts(in: pane.liveStore.state.timeline).last
        let activeText = pane.liveStore.state.activeParts[partID]?.text
        #expect(visibleText == expected)
        #expect(activeText == expected)
        #expect(visibleText?.utf8.count == expected.utf8.count)
        if let addedByteCount {
            #expect(expected.utf8.count - Self.firstTextA.utf8.count == addedByteCount)
        }
    }

    private func scrollSnapshot(
        pane: ConversationPaneController,
        viewport: DualPaneViewportFixture
    ) -> PaneScrollSnapshot {
        PaneScrollSnapshot(
            readingMode: pane.readingPosition.mode,
            scrollRequest: pane.scrollRequest,
            geometry: viewport.geometry
        )
    }

    private func containsToolResult(
        callID: String,
        in messages: [ProviderChatMessage]
    ) -> Bool {
        for message in messages {
            if case .toolResult(let toolCallID, _) = message, toolCallID == callID {
                return true
            }
        }
        return false
    }
}

private enum DualPaneHarnessError: Error, Sendable, CustomStringConvertible {
    case missingValue(String)
    case unexpectedEvent(String)
    case timedOut(String)
    case missingRun(String)

    var description: String {
        switch self {
        case .missingValue(let label): "missing value: \(label)"
        case .unexpectedEvent(let detail): detail
        case .timedOut(let label): "watchdog timed out: \(label)"
        case .missingRun(let runID): "no persisted Run found for event runID \(runID)"
        }
    }
}

private struct DualPaneDelivery: Sendable {
    let event: AgentEvent
    let ownerConversationID: String
}

private enum DualPaneDeliveryExpectation: Sendable {
    case partStarted(runID: String)
    case partDelta(runID: String, text: String)
    case approvalRequired(runID: String, toolCallID: String)
    case runState(runID: String, state: RunState)

    func matches(_ event: AgentEvent) -> Bool {
        switch (self, event) {
        case let (.partStarted(expectedRunID), .messagePartStarted(runID, _, _, _)):
            return runID == expectedRunID
        case let (.partDelta(expectedRunID, expectedText), .messagePartDelta(runID, _, delta)):
            return runID == expectedRunID && delta == expectedText
        case let (.approvalRequired(expectedRunID, expectedCallID), .approvalRequired(runID, callID)):
            return runID == expectedRunID && callID == expectedCallID
        case let (.runState(expectedRunID, expectedState), .runStateChanged(runID, state)):
            return runID == expectedRunID && state == expectedState
        default:
            return false
        }
    }
}

private actor DualPaneEventLog {
    private let continuation: AsyncStream<DualPaneDelivery>.Continuation
    private var errors: [String] = []

    init(continuation: AsyncStream<DualPaneDelivery>.Continuation) {
        self.continuation = continuation
    }

    func append(_ delivery: DualPaneDelivery) {
        continuation.yield(delivery)
    }

    func recordError(_ error: String) {
        errors.append(error)
    }

    func errorsSnapshot() -> [String] { errors }
}

private actor DualPaneDeliveryCursor {
    private var iterator: AsyncStream<DualPaneDelivery>.Iterator

    init(stream: AsyncStream<DualPaneDelivery>) {
        iterator = stream.makeAsyncIterator()
    }

    func wait(for expectation: DualPaneDeliveryExpectation) async -> DualPaneDelivery? {
        while let delivery = await iterator.next() {
            if expectation.matches(delivery.event) { return delivery }
        }
        return nil
    }
}

private actor DualConversationEventRouter {
    private let store: PersistenceStore
    private let paneA: ConversationPaneController
    private let paneB: ConversationPaneController
    private let eventLog: DualPaneEventLog

    init(
        store: PersistenceStore,
        paneA: ConversationPaneController,
        paneB: ConversationPaneController,
        eventLog: DualPaneEventLog
    ) {
        self.store = store
        self.paneA = paneA
        self.paneB = paneB
        self.eventLog = eventLog
    }

    func route(_ event: AgentEvent) async {
        let ownerConversationID: String
        do {
            ownerConversationID = try conversationID(for: event)
        } catch {
            await eventLog.recordError("route \(event): \(String(reflecting: error))")
            return
        }

        var consumeErrors: [String] = []
        do {
            _ = try await paneA.consume(event, in: ownerConversationID)
        } catch {
            consumeErrors.append("Pane A: \(String(reflecting: error))")
        }
        do {
            _ = try await paneB.consume(event, in: ownerConversationID)
        } catch {
            consumeErrors.append("Pane B: \(String(reflecting: error))")
        }
        if !consumeErrors.isEmpty {
            await eventLog.recordError(
                "consume \(event) for \(ownerConversationID): \(consumeErrors.joined(separator: "; "))"
            )
        }
        await eventLog.append(DualPaneDelivery(
            event: event,
            ownerConversationID: ownerConversationID
        ))
    }

    private func conversationID(for event: AgentEvent) throws -> String {
        if case .runAccepted(_, let conversationID) = event { return conversationID }

        let runID: String
        switch event {
        case .runAccepted:
            throw DualPaneHarnessError.unexpectedEvent("runAccepted requires its event conversationID")
        case .runStateChanged(let value, _),
             .messagePartStarted(let value, _, _, _),
             .messagePartDelta(let value, _, _),
             .messagePartCompleted(let value, _, _),
             .toolCallChanged(let value, _, _),
             .approvalRequired(let value, _),
             .runEnded(let value, _, _):
            runID = value
        }
        guard let run = try store.run(id: runID) else {
            throw DualPaneHarnessError.missingRun(runID)
        }
        return run.conversationID
    }
}

@MainActor
private final class DualPaneViewportFixture {
    private(set) var geometry: ScrollGeometry

    init(geometry: ScrollGeometry) {
        self.geometry = geometry
    }

    func measureLayout(viewportHeight: Double, contentHeight: Double) {
        geometry = ScrollGeometry(
            viewportHeight: viewportHeight,
            contentHeight: contentHeight,
            offset: geometry.offset
        )
    }

    @discardableResult
    func apply(
        _ request: ConversationPaneScrollRequest,
        to pane: ConversationPaneController,
        turnTops: [String: Double]
    ) -> Bool {
        guard pane.scrollRequest?.sequence == request.sequence else { return false }

        let appliedGeometry = applying(request.action, to: geometry, turnTops: turnTops)
        geometry = appliedGeometry
        _ = pane.updateReading(.programmaticScrolled(geometry: appliedGeometry))
        pane.markScrollApplied(sequence: request.sequence)
        return true
    }
}

@MainActor
private final class DualConversationPaneHarness {
    private static let watchdogDuration = Duration.seconds(10)
    private static let providerInstanceID = ProviderInstanceID(rawValue: "dual-pane-harness-instance")
    private static let modelID = Stage2GateFixture.modelID
    private static let credentialReference = CredentialReference(id: "dual-pane-harness-credential")

    let store: PersistenceStore
    let providerLedger: Stage2ProviderLedger
    let paneA: ConversationPaneController
    let paneB: ConversationPaneController
    let viewportA: DualPaneViewportFixture
    let viewportB: DualPaneViewportFixture
    let runtime: ConversationRuntime
    let eventLog: DualPaneEventLog

    private let deliveryCursor: DualPaneDeliveryCursor
    private let eventRouter: DualConversationEventRouter
    private let streamBoxes: [Stage2StreamBox]
    private var observedStreamBoxes: Set<ObjectIdentifier> = []

    init(
        scripts: [Stage2ProviderScript],
        toolRegistry: ToolRegistry = .empty,
        streamBoxes: [Stage2StreamBox] = [],
        initialGeometryA: ScrollGeometry = ScrollGeometry(
            viewportHeight: 400,
            contentHeight: 1_200,
            offset: 220
        ),
        initialGeometryB: ScrollGeometry = ScrollGeometry(
            viewportHeight: 350,
            contentHeight: 1_100,
            offset: 145
        )
    ) throws {
        let store = PersistenceStore(database: try ZenDatabase.inMemory())
        let credentials = CredentialStore(
            secrets: InMemorySecretBackend(),
            metadataRepository: InMemoryCredentialMetadataRepository()
        )
        try credentials.provision(
            SecretValue("dual-pane-harness-test-secret"),
            as: Self.credentialReference
        )

        let instance = ProviderInstance(
            id: Self.providerInstanceID,
            providerID: .deepSeek,
            displayName: "Dual Pane harness provider",
            baseURL: URL(string: "https://dual-pane-harness.invalid"),
            configRevision: .initial,
            credentialReference: Self.credentialReference
        )
        try store.createProviderInstance(instance)
        let conversationAID = DualConversationPaneConcurrencyTests.conversationA
        let conversationBID = DualConversationPaneConcurrencyTests.conversationB
        try store.database.write { db throws -> Void in
            try Fixtures.conversation(id: conversationAID).insert(db)
            try Fixtures.conversation(id: conversationBID).insert(db)
        }

        let configuration = ConversationComposerConfiguration(
            providerInstanceID: Self.providerInstanceID,
            modelID: Self.modelID
        )
        let paneA = try ConversationPaneController(
            conversationID: DualConversationPaneConcurrencyTests.conversationA,
            initialTimeline: try ConversationTimelineLoader.load(
                conversationID: DualConversationPaneConcurrencyTests.conversationA,
                from: store
            ),
            configuration: configuration,
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            loadTimeline: { requestedConversationID throws -> ConversationTimelineProjection in
                try ConversationTimelineLoader.load(conversationID: requestedConversationID, from: store)
            }
        )
        let paneB = try ConversationPaneController(
            conversationID: DualConversationPaneConcurrencyTests.conversationB,
            initialTimeline: try ConversationTimelineLoader.load(
                conversationID: DualConversationPaneConcurrencyTests.conversationB,
                from: store
            ),
            configuration: configuration,
            coalescer: StreamingCoalescer(interval: .milliseconds(0)),
            loadTimeline: { requestedConversationID throws -> ConversationTimelineProjection in
                try ConversationTimelineLoader.load(conversationID: requestedConversationID, from: store)
            }
        )

        let deliveryPair = AsyncStream<DualPaneDelivery>.makeStream()
        let eventLog = DualPaneEventLog(continuation: deliveryPair.continuation)
        let deliveryCursor = DualPaneDeliveryCursor(stream: deliveryPair.stream)
        let eventRouter = DualConversationEventRouter(
            store: store,
            paneA: paneA,
            paneB: paneB,
            eventLog: eventLog
        )
        let providerLedger = Stage2ProviderLedger()
        let provider = Stage2ScriptedProvider(ledger: providerLedger, scripts: scripts)
        let runtime = ConversationRuntime(
            store: store,
            provider: provider,
            credentials: credentials,
            onEvent: { event -> Void in
                await eventRouter.route(event)
            },
            toolRegistry: toolRegistry
        )

        self.store = store
        self.providerLedger = providerLedger
        self.paneA = paneA
        self.paneB = paneB
        self.viewportA = DualPaneViewportFixture(geometry: initialGeometryA)
        self.viewportB = DualPaneViewportFixture(geometry: initialGeometryB)
        self.eventLog = eventLog
        self.deliveryCursor = deliveryCursor
        self.eventRouter = eventRouter
        self.runtime = runtime
        self.streamBoxes = streamBoxes
    }

    func seedDistinctPaneState() {
        paneA.composer.draft = ComposerDraftState(
            text: "draft owned by pane A",
            selection: ComposerSelection(range: 7..<7),
            references: [],
            attachments: [],
            presentationState: .editing
        )
        paneB.composer.draft = ComposerDraftState(
            text: "draft owned by pane B",
            selection: ComposerSelection(range: 9..<9),
            references: [],
            attachments: [],
            presentationState: .editing
        )
        paneA.scrollBridge.userScrolled(
            geometry: viewportA.geometry,
            topVisibleTurn: (runID: "snapshot-anchor-a", turnTop: 190)
        )
        paneB.scrollBridge.userScrolled(
            geometry: viewportB.geometry,
            topVisibleTurn: (runID: "snapshot-anchor-b", turnTop: 180)
        )
    }

    func startRun(conversationID: String, text: String) async throws -> String {
        let runtime = self.runtime
        let command = SendCommand(
            conversationID: conversationID,
            text: text,
            providerInstanceID: Self.providerInstanceID,
            modelID: Self.modelID,
            maxProviderSteps: Stage2GateFixture.maxProviderSteps,
            submissionID: "dual-pane-\(UUID().uuidString)"
        )
        return try await withWatchdog(
            label: "start Run for \(conversationID)",
            duration: Self.watchdogDuration,
            operation: { () async throws -> String in
                try await runtime.start(command)
            }
        )
    }

    func waitForDelivery(
        _ expectation: DualPaneDeliveryExpectation,
        label: String
    ) async throws -> DualPaneDelivery {
        let cursor = deliveryCursor
        let delivery = try await withWatchdog(
            label: label,
            duration: Self.watchdogDuration,
            operation: { () async throws -> DualPaneDelivery? in
                await cursor.wait(for: expectation)
            }
        )
        guard let delivery else {
            throw DualPaneHarnessError.unexpectedEvent("delivery stream ended while waiting for \(label)")
        }
        return delivery
    }

    func snapshot(
        pane: ConversationPaneController,
        viewport: DualPaneViewportFixture
    ) async throws -> DualPanePaneSnapshot {
        let runtime = self.runtime
        let conversationID = pane.conversationID
        let persistedApprovals = try await withWatchdog(
            label: "read approval projection for \(conversationID)",
            duration: Self.watchdogDuration,
            operation: { () async throws -> [ToolApprovalProjection] in
                try await runtime.pendingToolApprovals(in: conversationID)
            }
        )
        return DualPanePaneSnapshot(
            liveState: pane.liveStore.state,
            paneApprovals: pane.liveStore.state.pendingToolApprovals,
            persistedApprovals: persistedApprovals,
            draft: pane.composer.draft,
            readingMode: pane.readingPosition.mode,
            scrollRequest: pane.scrollRequest,
            fixtureGeometry: viewport.geometry,
            droppedUnlocatableDeltas: pane.liveStore.droppedUnlocatableDeltas
        )
    }

    func requestsSnapshot() async throws -> [ProviderChatRequest] {
        let ledger = providerLedger
        return try await withWatchdog(
            label: "provider request ledger snapshot",
            duration: Self.watchdogDuration,
            operation: { () async throws -> [ProviderChatRequest] in
                await ledger.requestsSnapshot()
            }
        )
    }

    func projection(conversationID: String) async throws -> RunProjection? {
        let runtime = self.runtime
        return try await withWatchdog(
            label: "Run projection for \(conversationID)",
            duration: Self.watchdogDuration,
            operation: { () async throws -> RunProjection? in
                try await runtime.projection(conversationID: conversationID)
            }
        )
    }

    func pendingApprovals(conversationID: String) async throws -> [ToolApprovalProjection] {
        let runtime = self.runtime
        return try await withWatchdog(
            label: "pending approvals for \(conversationID)",
            duration: Self.watchdogDuration,
            operation: { () async throws -> [ToolApprovalProjection] in
                try await runtime.pendingToolApprovals(in: conversationID)
            }
        )
    }

    func refreshApprovals(in pane: ConversationPaneController) async throws {
        let runtime = self.runtime
        let conversationID = pane.conversationID
        try await withWatchdog(
            label: "refresh approval cards for \(conversationID)",
            duration: Self.watchdogDuration,
            operation: { () async throws -> Void in
                try await pane.refreshPendingApprovals(using: runtime)
            }
        )
    }

    func resolveApproval(_ request: ToolApprovalRequest) async throws {
        let runtime = self.runtime
        try await withWatchdog(
            label: "resolve approval \(request.toolCallID)",
            duration: Self.watchdogDuration,
            operation: { () async throws -> Void in
                try await runtime.resolveToolApproval(request)
            }
        )
    }

    func waitForCompletion(runID: String) async throws {
        let runtime = self.runtime
        try await withWatchdog(
            label: "Run \(runID) completion",
            duration: Self.watchdogDuration,
            operation: { () async throws -> Void in
                try await runtime.waitForCompletion(runID: runID)
            }
        )
    }

    func stop(runID: String) async throws {
        let runtime = self.runtime
        try await withWatchdog(
            label: "stop Run \(runID)",
            duration: Self.watchdogDuration,
            operation: { () async throws -> Void in
                try await runtime.stop(runID: runID)
            }
        )
        try await waitForCompletion(runID: runID)
    }

    func waitForCancellation(of box: Stage2StreamBox, label: String) async throws {
        let observed = observedStreamBoxes.contains(ObjectIdentifier(box))
        guard observed else { return }
        try await withWatchdog(
            label: label,
            duration: Self.watchdogDuration,
            operation: { () async throws -> Void in
                await box.waitUntilCancelled()
            }
        )
        #expect(box.cancellations > 0)
    }

    func markStreamObserved(_ box: Stage2StreamBox) {
        observedStreamBoxes.insert(ObjectIdentifier(box))
    }

    func stopActiveRuns() async {
        for conversationID in [
            DualConversationPaneConcurrencyTests.conversationA,
            DualConversationPaneConcurrencyTests.conversationB,
        ] {
            do {
                let activeRuns = try store.activeParentRuns(inConversation: conversationID)
                for run in activeRuns {
                    do {
                        try await stop(runID: run.id)
                    } catch {
                        Issue.record("cleanup could not stop Run \(run.id): \(String(reflecting: error))")
                    }
                }
            } catch {
                Issue.record("cleanup could not read active Runs for \(conversationID): \(String(reflecting: error))")
            }
        }

        for box in streamBoxes {
            do {
                try await waitForCancellation(of: box, label: "cleanup provider cancellation")
            } catch {
                Issue.record("cleanup did not observe provider cancellation: \(String(reflecting: error))")
            }
        }
    }
}

private struct DualPanePaneSnapshot: Equatable, Sendable {
    let liveState: LiveConversationState
    let paneApprovals: [ToolApprovalProjection]
    let persistedApprovals: [ToolApprovalProjection]
    let draft: ComposerDraftState
    let readingMode: ReadingMode
    let scrollRequest: ConversationPaneScrollRequest?
    let fixtureGeometry: ScrollGeometry
    let droppedUnlocatableDeltas: Int
}

private struct PaneScrollSnapshot: Equatable, Sendable {
    let readingMode: ReadingMode
    let scrollRequest: ConversationPaneScrollRequest?
    let geometry: ScrollGeometry
}

private func applying(
    _ action: ScrollAction,
    to geometry: ScrollGeometry,
    turnTops: [String: Double]
) -> ScrollGeometry {
    let offset: Double
    switch action {
    case .none:
        offset = geometry.offset
    case .scrollToBottom:
        offset = max(0, geometry.contentHeight - geometry.viewportHeight)
    case .restoreAnchor(let anchor):
        if let turnTop = turnTops[anchor.runID] {
            offset = turnTop - anchor.relativeViewportOffset * geometry.viewportHeight
        } else {
            offset = geometry.offset
        }
    case .maintainBottomEdge(let targetOffset):
        offset = targetOffset
    }
    return ScrollGeometry(
        viewportHeight: geometry.viewportHeight,
        contentHeight: geometry.contentHeight,
        offset: offset
    )
}

private func withWatchdog<Value: Sendable>(
    label: String,
    duration: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) -> Void in
        let race = DualPaneWatchdogRace(continuation: continuation)
        let operationTask = Task<Void, Never> { () async -> Void in
            do {
                race.finish(.success(try await operation()))
            } catch {
                race.finish(.failure(error))
            }
        }
        race.installOperation(operationTask)

        let watchdogTask = Task<Void, Never> { () async -> Void in
            do {
                try await Task.sleep(for: duration)
                race.finish(.failure(DualPaneHarnessError.timedOut(label)))
            } catch {
                return
            }
        }
        race.installWatchdog(watchdogTask)
    }
}

private final class DualPaneWatchdogRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var finished = false

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func installOperation(_ task: Task<Void, Never>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            task.cancel()
            return
        }
        operationTask = task
        lock.unlock()
    }

    func installWatchdog(_ task: Task<Void, Never>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            task.cancel()
            return
        }
        watchdogTask = task
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let operationTask = self.operationTask
        let watchdogTask = self.watchdogTask
        self.operationTask = nil
        self.watchdogTask = nil
        lock.unlock()

        operationTask?.cancel()
        watchdogTask?.cancel()
        continuation.resume(with: result)
    }
}
