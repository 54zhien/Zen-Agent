import Foundation
import Observation

/// One part that is still being produced. The store learns about it from
/// `messagePartStarted` and appends to it from `messagePartDelta`.
struct LivePartState: Sendable, Equatable {
    let runID: String
    let messageID: String
    let partID: String
    let kind: MessagePartKind
    var text: String
    /// A live part is created by `messagePartStarted`, so it starts in `.streaming`.
    /// Completion replaces this with the state carried by `messagePartCompleted`.
    var state: MessagePartState
}

/// The value a future view can read while the persisted timeline remains unchanged.
struct LiveConversationState: Sendable, Equatable {
    var timeline: ConversationTimelineProjection
    var activeParts: [String: LivePartState]
}

/// Applies the event stream to one live projection without rebuilding unrelated Turns.
///
/// A runtime that owns this store must await the main-actor hop:
/// `await MainActor.run { store.consume(event) }`. Because the callback waits for
/// `consume` to return, the runtime cannot advance its event loop past one event while
/// an earlier event is still being applied. Do not enqueue an unawaited task here.
@Observable
@MainActor
final class LiveConversationStore {
    private(set) var state: LiveConversationState
    private(set) var droppedUnlocatableDeltas: Int = 0

    private let coalescerTemplate: StreamingCoalescer
    private let now: @Sendable () -> ContinuousClock.Instant
    private var coalescers: [String: StreamingCoalescer] = [:]
    private var turnIndexByRunID: [String: Int]
    private var itemLocationByPartID: [String: LiveItemLocation] = [:]
    private var partIDsByRunID: [String: Set<String>] = [:]

    private struct LiveItemLocation {
        let turnIndex: Int
        let itemIndex: Int
    }

    init(
        projection: ConversationTimelineProjection,
        coalescer: StreamingCoalescer,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.state = LiveConversationState(
            timeline: projection,
            activeParts: [:]
        )
        self.coalescerTemplate = coalescer
        self.now = now

        var indices: [String: Int] = [:]
        for (index, turn) in projection.turns.enumerated() {
            indices[turn.runID] = index
        }
        self.turnIndexByRunID = indices
    }

    /// Consumes one business event and reports exactly the Turns rebuilt by this call.
    @discardableResult
    func consume(_ event: AgentEvent) -> Set<String> {
        var rebuiltRuns: Set<String> = []

        switch event {
        case .messagePartStarted(let runID, let messageID, let partID, let kind):
            consumeStarted(
                runID: runID,
                messageID: messageID,
                partID: partID,
                kind: kind,
                rebuiltRuns: &rebuiltRuns
            )

        case .messagePartDelta(let runID, let partID, let delta):
            consumeDelta(
                runID: runID,
                partID: partID,
                delta: delta,
                rebuiltRuns: &rebuiltRuns
            )

        case .messagePartCompleted(let runID, let partID, let partState):
            consumeCompleted(
                runID: runID,
                partID: partID,
                state: partState,
                rebuiltRuns: &rebuiltRuns
            )

        case .runEnded(let runID, _, _):
            consumeRunEnded(runID: runID, rebuiltRuns: &rebuiltRuns)

        case .runAccepted,
             .runStateChanged,
             .toolCallChanged,
             .approvalRequired:
            break
        }

        return rebuiltRuns
    }

    private func consumeStarted(
        runID: String,
        messageID: String,
        partID: String,
        kind: MessagePartKind,
        rebuiltRuns: inout Set<String>
    ) {
        let part = LivePartState(
            runID: runID,
            messageID: messageID,
            partID: partID,
            kind: kind,
            text: "",
            state: .streaming
        )
        register(part)

        switch kind {
        case .text:
            appendLiveItem(.assistantText(""), for: part, rebuiltRuns: &rebuiltRuns)
        case .reasoning:
            appendLiveItem(.reasoning(""), for: part, rebuiltRuns: &rebuiltRuns)
        case .toolCall, .toolResult:
            break
        }
    }

    private func consumeDelta(
        runID: String,
        partID: String,
        delta: String,
        rebuiltRuns: inout Set<String>
    ) {
        guard let part = state.activeParts[partID], part.runID == runID else {
            droppedUnlocatableDeltas += 1
            return
        }
        guard !delta.isEmpty else { return }

        var coalescer = coalescers[partID] ?? coalescerTemplate
        let readyText = coalescer.append(delta, at: now())
        coalescers[partID] = coalescer

        guard let readyText else { return }
        apply(readyText, to: partID, rebuiltRuns: &rebuiltRuns)
    }

    private func consumeCompleted(
        runID: String,
        partID: String,
        state partState: MessagePartState,
        rebuiltRuns: inout Set<String>
    ) {
        guard let part = state.activeParts[partID], part.runID == runID else { return }

        // Completion is a semantic boundary, so it must publish text still held by the
        // time coalescer before changing the part's state.
        flush(partID: partID, rebuiltRuns: &rebuiltRuns)

        guard var completedPart = state.activeParts[partID], completedPart.runID == runID else {
            return
        }
        completedPart.state = partState
        state.activeParts[partID] = completedPart
        if let location = itemLocationByPartID[partID],
           location.turnIndex < state.timeline.turns.count,
           partState == .completed {
            var sources = state.timeline.turns[location.turnIndex].textSourcesByItemIndex
            sources[location.itemIndex] = TimelineTextSource(
                conversationID: state.timeline.conversationID,
                messageID: completedPart.messageID,
                partID: completedPart.partID,
                isCompleted: true
            )
            let items = state.timeline.turns[location.turnIndex].items
            replaceTurn(at: location.turnIndex, with: items, textSourcesByItemIndex: sources)
            rebuiltRuns.insert(runID)
        }
        // Keep the completed value readable until runEnded performs the run-wide cleanup.
    }

    private func consumeRunEnded(
        runID: String,
        rebuiltRuns: inout Set<String>
    ) {
        let partIDs = partIDsByRunID[runID] ?? []
        for partID in partIDs {
            // runEnded is another semantic boundary: no pending delta may be lost merely
            // because the stream ended before the display interval elapsed.
            flush(partID: partID, rebuiltRuns: &rebuiltRuns)
            state.activeParts.removeValue(forKey: partID)
            coalescers.removeValue(forKey: partID)
            itemLocationByPartID.removeValue(forKey: partID)
        }
        partIDsByRunID.removeValue(forKey: runID)
    }

    private func register(_ part: LivePartState) {
        if let previous = state.activeParts[part.partID] {
            removePartID(part.partID, fromRunID: previous.runID)
            itemLocationByPartID.removeValue(forKey: part.partID)
        }

        state.activeParts[part.partID] = part
        coalescers[part.partID] = coalescerTemplate
        partIDsByRunID[part.runID, default: []].insert(part.partID)
    }

    private func removePartID(_ partID: String, fromRunID runID: String) {
        guard var partIDs = partIDsByRunID[runID] else { return }
        partIDs.remove(partID)
        if partIDs.isEmpty {
            partIDsByRunID.removeValue(forKey: runID)
        } else {
            partIDsByRunID[runID] = partIDs
        }
    }

    private func appendLiveItem(
        _ item: TimelineItem,
        for part: LivePartState,
        rebuiltRuns: inout Set<String>
    ) {
        guard let turnIndex = turnIndexByRunID[part.runID],
              state.timeline.turns.indices.contains(turnIndex)
        else { return }

        var items = state.timeline.turns[turnIndex].items
        items.append(item)
        let itemIndex = items.count - 1
        var sources = state.timeline.turns[turnIndex].textSourcesByItemIndex
        if case .assistantText = item {
            sources[itemIndex] = TimelineTextSource(
                conversationID: state.timeline.conversationID,
                messageID: part.messageID,
                partID: part.partID,
                isCompleted: part.state == .completed
            )
        }
        replaceTurn(at: turnIndex, with: items, textSourcesByItemIndex: sources)
        itemLocationByPartID[part.partID] = LiveItemLocation(
            turnIndex: turnIndex,
            itemIndex: itemIndex
        )
        rebuiltRuns.insert(part.runID)
    }

    private func apply(
        _ readyText: String,
        to partID: String,
        rebuiltRuns: inout Set<String>
    ) {
        guard var part = state.activeParts[partID] else { return }
        part.text.append(contentsOf: readyText)
        state.activeParts[partID] = part

        guard let location = itemLocationByPartID[partID],
              state.timeline.turns.indices.contains(location.turnIndex)
        else { return }

        var items = state.timeline.turns[location.turnIndex].items
        guard items.indices.contains(location.itemIndex) else { return }

        switch part.kind {
        case .text:
            items[location.itemIndex] = .assistantText(part.text)
        case .reasoning:
            items[location.itemIndex] = .reasoning(part.text)
        case .toolCall, .toolResult:
            return
        }

        replaceTurn(at: location.turnIndex, with: items)
        rebuiltRuns.insert(part.runID)
    }

    private func flush(
        partID: String,
        rebuiltRuns: inout Set<String>
    ) {
        guard var coalescer = coalescers[partID] else { return }
        if let readyText = coalescer.flush() {
            apply(readyText, to: partID, rebuiltRuns: &rebuiltRuns)
        }
        coalescers[partID] = coalescer
    }

    private func replaceTurn(
        at turnIndex: Int,
        with items: [TimelineItem],
        textSourcesByItemIndex: [Int: TimelineTextSource]? = nil
    ) {
        var turns = state.timeline.turns
        let runID = turns[turnIndex].runID
        turns[turnIndex] = ConversationTurn(
            runID: runID,
            items: items,
            textSourcesByItemIndex: textSourcesByItemIndex
                ?? turns[turnIndex].textSourcesByItemIndex
        )
        state.timeline = ConversationTimelineProjection(
            conversationID: state.timeline.conversationID,
            turns: turns
        )
    }
}
