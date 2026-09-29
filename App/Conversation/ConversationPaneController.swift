import Foundation
import Observation

enum ConversationPaneError: Error, Equatable {
    case asynchronousLoadRequired
    case mismatchedTimeline(expected: String, actual: String)
    case mismatchedSession(expected: String, actual: String)
}

struct ConversationPaneScrollRequest: Equatable, Sendable {
    let sequence: UInt64
    let action: ScrollAction
}

@Observable
@MainActor
final class ConversationPaneController {
    let conversationID: String
    let session: ConversationSession
    private(set) var liveStore: LiveConversationStore
    let readingPosition: ReadingPositionController
    let composer: ComposerController
    private(set) var scrollRequest: ConversationPaneScrollRequest?

    @ObservationIgnored private let coalescer: StreamingCoalescer
    @ObservationIgnored private let loadTimeline: @MainActor (String) throws -> ConversationTimelineProjection
    @ObservationIgnored private let asynchronousLoad: (@MainActor (String) async throws -> ConversationTimelineProjection)?
    @ObservationIgnored private var nextScrollSequence: UInt64 = 0
    @ObservationIgnored private var appliedGeometry: (sequence: UInt64, geometry: ScrollGeometry)?
    @ObservationIgnored private var cachedScrollBridge: ConversationPaneScrollBridge?

    init(
        conversationID: String,
        initialTimeline: ConversationTimelineProjection,
        configuration: ConversationComposerConfiguration?,
        sendAvailability: ComposerSendAvailability? = nil,
        session: ConversationSession? = nil,
        coalescer: StreamingCoalescer,
        tolerance: Double = 12,
        loadTimeline: @escaping @MainActor (String) throws -> ConversationTimelineProjection = { _ in
            throw ConversationPaneError.asynchronousLoadRequired
        },
        asynchronousLoad: (@MainActor (String) async throws -> ConversationTimelineProjection)? = nil
    ) throws {
        guard initialTimeline.conversationID == conversationID else {
            throw ConversationPaneError.mismatchedTimeline(
                expected: conversationID,
                actual: initialTimeline.conversationID
            )
        }

        if let session, session.conversationID != conversationID {
            throw ConversationPaneError.mismatchedSession(expected: conversationID, actual: session.conversationID)
        }
        let owner = session ?? ConversationSession(conversationID: conversationID,
            configuration: configuration, sendAvailability: sendAvailability, tolerance: tolerance)
        self.conversationID = conversationID
        self.session = owner
        self.liveStore = LiveConversationStore(
            projection: initialTimeline,
            coalescer: coalescer
        )
        self.readingPosition = owner.readingPosition
        self.composer = owner.composer
        self.coalescer = coalescer
        self.loadTimeline = loadTimeline
        self.asynchronousLoad = asynchronousLoad
        if session != nil {
            switch readingPosition.mode {
            case .followingBottom: enqueue(.scrollToBottom)
            case .reading(let anchor, _): enqueue(.restoreAnchor(anchor))
            }
        }
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

    func loadTimelineAsync() async throws -> ConversationTimelineProjection {
        if let asynchronousLoad { return try await asynchronousLoad(conversationID) }
        // Synthetic Pane tests can supply a pure synchronous projection closure.
        return try loadTimeline(conversationID)
    }

    func applyHiddenStoreChanges(_ changedRunIDs: Set<String>) {
        enqueue(readingPosition.applyStoreChanges(changedRunIDs).action)
    }

    func flushStreamingText() {
        let changed = liveStore.flushStreamingText()
        if !changed.isEmpty { enqueue(readingPosition.applyStoreChanges(changed).action) }
    }

    func adoptLiveStore(_ store: LiveConversationStore) throws {
        guard store.state.timeline.conversationID == conversationID else {
            throw ConversationPaneError.mismatchedTimeline(
                expected: conversationID,
                actual: store.state.timeline.conversationID
            )
        }
        liveStore = store
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

        if case .composerHeightChanged(let geometry, _) = event,
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

#if DEBUG
    var previewReadingDiagnosticForUITest = ""
    var previewReadingBootstrapForUITest: String?

    func restoreAnchorForUITest(_ anchor: TurnAnchor) {
        readingPosition.setReadingAnchorForUITest(anchor)
        enqueue(.restoreAnchor(anchor))
    }
#endif

    func refreshPendingApprovals(using runtime: ConversationRuntime) async throws {
        try await liveStore.refreshPendingToolApprovals(using: runtime)
    }

    private func reloadTimelineAndReportNewRuns() throws -> Set<String> {
        let timeline = try loadTimeline(conversationID)
        return try applyTimeline(timeline)
    }

    @discardableResult
    func applyTimeline(_ timeline: ConversationTimelineProjection) throws -> Set<String> {
        let previousRunIDs = Set(liveStore.state.timeline.turns.map(\.runID))
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
