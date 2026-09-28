import Foundation
import Observation

@MainActor
@Observable
final class RunEventRouter {
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

    @ObservationIgnored private var conversationByRunID: [String: String] = [:]
    @ObservationIgnored private var activeRunIDsByConversationID: [String: Set<String>] = [:]
    @ObservationIgnored private var panesByConversationID: [String: PaneRegistration] = [:]
    @ObservationIgnored private var partsByRunID: [String: [String: PartIdentity]] = [:]
    @ObservationIgnored private var needsReload: Set<String> = []
    @ObservationIgnored private var hiddenChanges: [String: Set<String>] = [:]
    @ObservationIgnored private var terminalCheckpoints: [String: AgentEvent] = [:]
    private(set) var diagnostics: [String] = []
    private(set) var recoveryMessages: [String: String] = [:]

    /// Runtime owns these Runs; registration only establishes their display route.
    func registerRecoveredRun(runID: String, conversationID: String) {
        if let existing = conversationByRunID[runID] {
            if existing != conversationID { record("Run ownership conflict for \(runID)") }
            return
        }
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
            route(event, to: conversationID)
            return
        }

        let runID = Self.runID(for: event)
        guard let conversationID = conversationByRunID[runID] else {
            record("Dropped unregistered Run event for \(runID)")
            return
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
        // Presentation detachment never owns Stop. Runtime has already persisted
        // visible Part events before publication, so no hidden token queue is needed.
        needsReload.insert(conversationID)
    }

    func hasActiveRun(for conversationID: String) -> Bool {
        !(activeRunIDsByConversationID[conversationID]?.isEmpty ?? true)
    }

    func recoveryMessage(for conversationID: String) -> String? { recoveryMessages[conversationID] }

    @discardableResult
    func retryTimelineLoad(for conversationID: String) -> Bool {
        guard let registration = panesByConversationID[conversationID],
              registration.state == .waitingForRecovery else { return false }
        do {
            try registration.pane.reloadTimeline()
            try reconcile(registration.pane)
            return true
        } catch {
            markRecovery(for: conversationID, runID: nil)
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
