import Foundation
import Observation

@MainActor
@Observable
final class RunEventRouter {
    let historyPreparation = ConversationHistoryPreparation()
    private enum PaneLoadState: Equatable { case ready, waitingForRecovery }
    private enum ReconciliationError: Error { case pendingReload }
    private struct PaneRegistration {
        let pane: ConversationPaneController
        var state: PaneLoadState
    }
    private struct PartIdentity {
        let runID: String
        let messageID: String
        let partID: String
        let kind: MessagePartKind
    }
    private struct PreparationJournal {
        var events: [AgentEvent] = []
        var bytes = 0
        var overflowed = false

        mutating func append(_ event: AgentEvent) {
            guard !overflowed else { return }
            if case .messagePartDelta(_, _, let delta, _) = event { bytes += delta.utf8.count }
            // A temporary catch-up budget, not a limit on conversation history.
            guard bytes <= 256 * 1024 else { overflowed = true; events.removeAll(); return }
            if case .messagePartDelta(let run, let part, let delta, let end) = event,
               case .messagePartDelta(let oldRun, let oldPart, let oldDelta, let oldEnd) = events.last,
               run == oldRun, part == oldPart, oldEnd == end - delta.utf8.count {
                events[events.count - 1] = .messagePartDelta(runID: run, partID: part,
                    delta: oldDelta + delta, endUTF8Offset: end)
            } else {
                guard events.count < 512 else { overflowed = true; events.removeAll(); return }
                events.append(event)
            }
        }
    }

    @ObservationIgnored private var conversationByRunID: [String: String] = [:]
    @ObservationIgnored private var activeRunIDsByConversationID: [String: Set<String>] = [:]
    @ObservationIgnored private var panesByConversationID: [String: PaneRegistration] = [:]
    @ObservationIgnored private var partsByRunID: [String: [String: PartIdentity]] = [:]
    @ObservationIgnored private var needsReload: Set<String> = []
    @ObservationIgnored private var preparationTickets: [String: UUID] = [:]
    @ObservationIgnored private var preparationJournals: [String: PreparationJournal] = [:]
    @ObservationIgnored private var hiddenChanges: [String: Set<String>] = [:]
    @ObservationIgnored private var terminalCheckpoints: [String: AgentEvent] = [:]
    private(set) var diagnostics: [String] = []
    private(set) var recoveryMessages: [String: String] = [:]
    private(set) var lastHandoffDuration: Duration = .zero

    /// Runtime owns these Runs; registration only establishes their display route.
    func registerRecoveredRun(runID: String, conversationID: String) {
        if let existing = conversationByRunID[runID] {
            if existing != conversationID { record("Run ownership conflict for \(runID)") }
            return
        }
        invalidatePreparation(for: conversationID)
        conversationByRunID[runID] = conversationID
        activeRunIDsByConversationID[conversationID, default: []].insert(runID)
    }

    func handle(_ event: AgentEvent) async {
        if case .runAccepted(let runID, let conversationID) = event {
            if let existing = conversationByRunID[runID] {
                if existing != conversationID { record("Run ownership conflict for \(runID)") }
                return
            }
            registerRecoveredRun(runID: runID, conversationID: conversationID)
            terminalCheckpoints.removeValue(forKey: conversationID)
            if panesByConversationID[conversationID]?.state == .ready {
                _ = await reloadPane(for: conversationID)
            } else {
                markHidden(event, in: conversationID)
            }
            return
        }

        let runID = Self.runID(for: event)
        guard let conversationID = conversationByRunID[runID] else {
            record("Dropped unregistered Run event for \(runID)")
            return
        }
        if case .toolCallChanged = event {
            invalidatePreparation(for: conversationID)
        } else if case .approvalRequired = event {
            invalidatePreparation(for: conversationID)
        } else {
            preparationJournals[conversationID]?.append(event)
        }
        switch event {
        case .messagePartStarted(_, let messageID, let partID, let kind):
            if kind == .text || kind == .reasoning {
                partsByRunID[runID, default: [:]][partID] = PartIdentity(
                    runID: runID, messageID: messageID, partID: partID, kind: kind)
            }
        case .messagePartCompleted(_, let partID, _):
            partsByRunID[runID]?.removeValue(forKey: partID)
        default: break
        }
        route(event, to: conversationID)
        if case .runEnded = event {
            // An End already delivered to the visible Pane is not unread work
            // to replay on a later mount of the same session.
            if panesByConversationID[conversationID]?.state != .ready {
                terminalCheckpoints[conversationID] = event
            }
            conversationByRunID.removeValue(forKey: runID)
            partsByRunID.removeValue(forKey: runID)
            activeRunIDsByConversationID[conversationID]?.remove(runID)
            if activeRunIDsByConversationID[conversationID]?.isEmpty == true {
                activeRunIDsByConversationID.removeValue(forKey: conversationID)
            }
        }
    }

    func beginPanePreparation(for id: String) -> UUID {
        let ticket = UUID()
        preparationTickets[id] = ticket
        preparationJournals[id] = PreparationJournal()
        return ticket
    }

    func acceptsPanePreparation(for id: String, ticket: UUID) -> Bool {
        preparationTickets[id] == ticket
    }

    func cancelPanePreparation(for id: String, ticket: UUID? = nil) {
        if ticket == nil || preparationTickets[id] == ticket {
            preparationTickets.removeValue(forKey: id)
            preparationJournals.removeValue(forKey: id)
        }
    }

    private func invalidatePreparation(for id: String) {
        // Structural changes need a new projection. Text growth is replayed by offset.
        cancelPanePreparation(for: id)
    }

    func registerPreparedPane(_ pane: ConversationPaneController, ticket: UUID) -> Bool {
        let clock = ContinuousClock()
        let began = clock.now
        defer { lastHandoffDuration = began.duration(to: clock.now) }
        let id = pane.conversationID
        guard acceptsPanePreparation(for: id, ticket: ticket), panesByConversationID[id] == nil else { return false }
        let journal = preparationJournals[id] ?? PreparationJournal()
        cancelPanePreparation(for: id, ticket: ticket)
        guard !journal.overflowed else { return false }
        panesByConversationID[id] = PaneRegistration(pane: pane, state: .ready)
        do {
            try replay(journal.events, in: pane)
            // The just-loaded projection replaces the dirty read. No second
            // synchronous full-history read is needed on the presentation actor.
            try reconcile(pane)
            return true
        } catch {
            panesByConversationID.removeValue(forKey: id)
            return false
        }
    }

    private func replay(_ events: [AgentEvent], in pane: ConversationPaneController) throws {
        guard !events.isEmpty else { return }
        let replayRunIDs = Set(events.map(Self.runID(for:)))
        let persistedPartIDs = Set(pane.liveStore.state.timeline.turns.flatMap {
            $0.textSourcesByItemIndex.values.map(\.partID)
        })
        // An End received during the read may already have removed Runtime routing.
        // Snapshot Parts still provide the identity and the persisted replay lower bound.
        for turn in pane.liveStore.state.timeline.turns where replayRunIDs.contains(turn.runID) {
            for (index, source) in turn.textSourcesByItemIndex
            where source.canResume && turn.items.indices.contains(index) {
                let kind: MessagePartKind
                switch turn.items[index] {
                case .assistantText: kind = .text
                case .reasoning: kind = .reasoning
                default: continue
                }
                _ = pane.liveStore.resumePersistedPart(runID: turn.runID, messageID: source.messageID,
                    partID: source.partID, kind: kind)
            }
        }
        for event in events {
            if case .messagePartStarted(_, _, let partID, _) = event,
               persistedPartIDs.contains(partID) { continue }
            _ = try pane.consume(event, in: pane.conversationID)
            if case .runEnded = event { terminalCheckpoints.removeValue(forKey: pane.conversationID) }
        }
    }

    @discardableResult
    func registerPane(_ pane: ConversationPaneController) -> Bool {
        let id = pane.conversationID
        guard panesByConversationID[id] == nil else {
            record("Rejected duplicate Pane registration for \(id)")
            return false
        }
        let state: PaneLoadState = recoveryMessages[id] == nil ? .ready : .waitingForRecovery
        panesByConversationID[id] = PaneRegistration(pane: pane, state: state)
        guard state == .ready else { return true }
        do {
            if needsReload.contains(id) { try pane.reloadTimeline() }
            try reconcile(pane)
        } catch {
            markRecovery(for: id, runID: nil)
        }
        return true
    }

    func unregisterPane(for conversationID: String) {
        guard panesByConversationID.removeValue(forKey: conversationID) != nil else { return }
        cancelPanePreparation(for: conversationID)
        // Presentation detachment never owns Stop. Runtime has already persisted
        // visible Part events before publication, so no hidden token queue is needed.
        needsReload.insert(conversationID)
    }

    func hasActiveRun(for conversationID: String) -> Bool {
        !(activeRunIDsByConversationID[conversationID]?.isEmpty ?? true)
    }

    func recoveryMessage(for conversationID: String) -> String? { recoveryMessages[conversationID] }

    @discardableResult
    func retryTimelineLoad(for conversationID: String) async -> Bool {
        guard let registration = panesByConversationID[conversationID],
              registration.state == .waitingForRecovery else { return false }
        return await reloadPane(for: conversationID)
    }

    private func reloadPane(for conversationID: String) async -> Bool {
        guard let registration = panesByConversationID[conversationID] else { return false }
        panesByConversationID[conversationID]?.state = .waitingForRecovery
        let ticket = beginPanePreparation(for: conversationID)
        defer { cancelPanePreparation(for: conversationID, ticket: ticket) }
        do {
            let timeline = try await registration.pane.loadTimelineAsync()
            guard !Task.isCancelled,
                  panesByConversationID[conversationID]?.pane === registration.pane,
                  acceptsPanePreparation(for: conversationID, ticket: ticket) else { throw CancellationError() }
            let journal = preparationJournals[conversationID] ?? PreparationJournal()
            guard !journal.overflowed else { throw ReconciliationError.pendingReload }
            cancelPanePreparation(for: conversationID, ticket: ticket)
            try registration.pane.applyTimeline(timeline)
            try replay(journal.events, in: registration.pane)
            try reconcile(registration.pane)
            return true
        } catch {
            if panesByConversationID[conversationID]?.pane === registration.pane,
               preparationTickets[conversationID] == nil || preparationTickets[conversationID] == ticket {
                markRecovery(for: conversationID, runID: nil)
            }
            return false
        }
    }

    private func route(_ event: AgentEvent, to conversationID: String) {
        guard let registration = panesByConversationID[conversationID],
              registration.state == .ready else {
            markHidden(event, in: conversationID)
            return
        }
        let pane = registration.pane
        do {
            if case .messagePartStarted(let runID, let messageID, let partID, let kind) = event,
               pane.liveStore.resumePersistedPart(
                   runID: runID, messageID: messageID, partID: partID, kind: kind) {
                return
            }
            _ = try pane.consume(event, in: conversationID)
            if pane.liveStore.needsTimelineReload {
                markHidden(event, in: conversationID)
                markRecovery(for: conversationID, runID: Self.runID(for: event))
            } else if case .runAccepted = event {
                resumeParts(in: pane)
            }
        } catch {
            markHidden(event, in: conversationID)
            markRecovery(for: conversationID, runID: Self.runID(for: event))
        }
    }

    private func markHidden(_ event: AgentEvent, in conversationID: String) {
        needsReload.insert(conversationID)
        hiddenChanges[conversationID, default: []].insert(Self.runID(for: event))
    }

    private func reconcile(_ pane: ConversationPaneController) throws {
        let id = pane.conversationID
        resumeParts(in: pane)
        if let terminal = terminalCheckpoints[id] {
            _ = try pane.consume(terminal, in: id)
        }
        guard !pane.liveStore.needsTimelineReload else {
            throw ReconciliationError.pendingReload
        }
        pane.applyHiddenStoreChanges(hiddenChanges.removeValue(forKey: id) ?? [])
        needsReload.remove(id)
        terminalCheckpoints.removeValue(forKey: id)
        recoveryMessages.removeValue(forKey: id)
        panesByConversationID[id] = PaneRegistration(pane: pane, state: .ready)
    }

    private func resumeParts(in pane: ConversationPaneController) {
        let active = activeRunIDsByConversationID[pane.conversationID] ?? []
        for runID in active {
            guard let parts = partsByRunID[runID] else { continue }
            for part in parts.values {
                _ = pane.liveStore.resumePersistedPart(runID: runID, messageID: part.messageID,
                    partID: part.partID, kind: part.kind)
            }
        }
        // A recovered or remounted Run may have persisted its Start before the
        // router was attached. Stable persisted sources cover that acknowledgement gap.
        for turn in pane.liveStore.state.timeline.turns where active.contains(turn.runID) {
            for (index, source) in turn.textSourcesByItemIndex
            where source.canResume && turn.items.indices.contains(index) {
                let kind: MessagePartKind
                switch turn.items[index] {
                case .assistantText: kind = .text
                case .reasoning: kind = .reasoning
                default: continue
                }
                _ = pane.liveStore.resumePersistedPart(runID: turn.runID, messageID: source.messageID,
                    partID: source.partID, kind: kind)
            }
        }
    }

    private func markRecovery(for conversationID: String, runID: String?) {
        if var registration = panesByConversationID[conversationID] {
            registration.state = .waitingForRecovery
            panesByConversationID[conversationID] = registration
        }
        needsReload.insert(conversationID)
        recoveryMessages[conversationID] = "无法加载会话内容，请重试。"
        record("Timeline reconciliation failed for \(runID ?? conversationID)")
    }

    private func record(_ diagnostic: String) {
        diagnostics.append(diagnostic)
        if diagnostics.count > 64 { diagnostics.removeFirst(diagnostics.count - 64) }
    }

    private static func runID(for event: AgentEvent) -> String {
        switch event {
        case .runAccepted(let runID, _), .runStateChanged(let runID, _),
             .messagePartStarted(let runID, _, _, _), .messagePartDelta(let runID, _, _, _),
             .messagePartCompleted(let runID, _, _), .toolCallChanged(let runID, _, _),
             .approvalRequired(let runID, _), .runEnded(let runID, _, _): return runID
        }
    }
}
