import Foundation
import Observation

enum ConversationPaneError: Error, Equatable {
    case mismatchedTimeline(expected: String, actual: String)
}

struct ConversationPaneScrollRequest: Equatable, Sendable {
    let sequence: UInt64
    let action: ScrollAction
}

@Observable
@MainActor
final class ConversationPaneController {
    let conversationID: String
    private(set) var liveStore: LiveConversationStore
    let readingPosition: ReadingPositionController
    let composer: ComposerController
    private(set) var scrollRequest: ConversationPaneScrollRequest?

    @ObservationIgnored private let coalescer: StreamingCoalescer
    @ObservationIgnored private let loadTimeline: @MainActor (String) throws -> ConversationTimelineProjection
    @ObservationIgnored private var nextScrollSequence: UInt64 = 0
    @ObservationIgnored private var appliedGeometry: (sequence: UInt64, geometry: ScrollGeometry)?
    @ObservationIgnored private var cachedScrollBridge: ConversationPaneScrollBridge?

    init(
        conversationID: String,
        initialTimeline: ConversationTimelineProjection,
        configuration: ConversationComposerConfiguration,
        coalescer: StreamingCoalescer,
        tolerance: Double = 12,
        loadTimeline: @escaping @MainActor (String) throws -> ConversationTimelineProjection
    ) throws {
        guard initialTimeline.conversationID == conversationID else {
            throw ConversationPaneError.mismatchedTimeline(
                expected: conversationID,
                actual: initialTimeline.conversationID
            )
        }

        self.conversationID = conversationID
        self.liveStore = LiveConversationStore(
            projection: initialTimeline,
            coalescer: coalescer
        )
        self.readingPosition = ReadingPositionController(tolerance: tolerance)
        self.composer = ComposerController(configuration: configuration)
        self.coalescer = coalescer
        self.loadTimeline = loadTimeline
    }

    var scrollBridge: ConversationPaneScrollBridge {
        if let cachedScrollBridge {
            return cachedScrollBridge
        }
        let bridge = ConversationPaneScrollBridge(pane: self)
        cachedScrollBridge = bridge
        return bridge
    }

    @discardableResult
    func consume(_ event: AgentEvent, in ownerConversationID: String) throws -> Set<String> {
        guard ownerConversationID == conversationID else { return [] }

        if case let .runAccepted(_, eventConversationID) = event {
            guard eventConversationID == ownerConversationID,
                  eventConversationID == conversationID
            else { return [] }
            return try reloadTimelineAndReportNewRuns()
        }

        let changedRunIDs = liveStore.consume(event)
        guard !changedRunIDs.isEmpty else { return changedRunIDs }
        enqueue(readingPosition.applyStoreChanges(changedRunIDs).action)
        return changedRunIDs
    }

    @discardableResult
    func reloadTimeline() throws -> Set<String> {
        try reloadTimelineAndReportNewRuns()
    }

    @discardableResult
    func updateReading(_ event: ReadingPositionEvent) -> ReadingPositionOutput {
        if case .userScrolled(let geometry, _) = event {
            scrollRequest = nil
            appliedGeometry = nil
            guard geometry.isUsableForPane else { return currentReadingOutput() }
        }

        if case .programmaticScrolled(let geometry) = event,
           let request = scrollRequest {
            guard geometry.isUsableForPane else { return currentReadingOutput() }
            appliedGeometry = (request.sequence, geometry)
            return currentReadingOutput()
        }

        if case .geometryChanged(let geometry, _) = event,
           !geometry.isUsableForPane {
            return currentReadingOutput()
        }

        let output = readingPosition.apply(event)
        enqueue(output.action)
        return output
    }

    func markScrollApplied(sequence: UInt64) {
        guard let request = scrollRequest,
              request.sequence == sequence,
              let appliedGeometry,
              appliedGeometry.sequence == sequence
        else { return }

        scrollRequest = nil
        self.appliedGeometry = nil
        _ = readingPosition.apply(.programmaticScrolled(geometry: appliedGeometry.geometry))
    }

    func refreshPendingApprovals(using runtime: ConversationRuntime) async throws {
        try await liveStore.refreshPendingToolApprovals(using: runtime)
    }

    private func reloadTimelineAndReportNewRuns() throws -> Set<String> {
        let previousRunIDs = Set(liveStore.state.timeline.turns.map(\.runID))
        let timeline = try loadTimeline(conversationID)
        guard timeline.conversationID == conversationID else {
            throw ConversationPaneError.mismatchedTimeline(
                expected: conversationID,
                actual: timeline.conversationID
            )
        }

        let existingApprovals = liveStore.state.pendingToolApprovals
        let replacement = LiveConversationStore(
            projection: timeline,
            coalescer: coalescer
        )
        replacement.reconcilePendingToolApprovals(existingApprovals)
        liveStore = replacement

        let loadedRunIDs = Set(timeline.turns.map(\.runID))
        let addedRunIDs = loadedRunIDs.subtracting(previousRunIDs)
        guard !addedRunIDs.isEmpty else { return [] }
        enqueue(readingPosition.applyStoreChanges(addedRunIDs).action)
        return addedRunIDs
    }

    private func enqueue(_ action: ScrollAction) {
        guard action != .none else { return }
        precondition(nextScrollSequence < UInt64.max, "Conversation pane scroll sequence exhausted")
        nextScrollSequence += 1
        scrollRequest = ConversationPaneScrollRequest(
            sequence: nextScrollSequence,
            action: action
        )
        appliedGeometry = nil
    }

    private func currentReadingOutput() -> ReadingPositionOutput {
        ReadingPositionOutput(
            mode: readingPosition.mode,
            action: .none,
            showsNewContentCapsule: readingPosition.showsNewContentCapsule,
            newContentCount: readingPosition.newContentCount
        )
    }
}
