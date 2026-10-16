import SwiftUI
import Observation

/// Workspace retains both Pane owners until their final native layout receipts.
/// Runtime and Session lifetime remain with their existing owners.
@MainActor
@Observable
final class SplitResizeController {
    private(set) var closeIntent: SplitDropSlot?
    private(set) var isActive = false
    private(set) var isClosing = false
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var arrangement: SplitWorkspaceState?
    @ObservationIgnored private var participants: [ConversationPaneController] = []
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var rawRatio = 0.5
    @ObservationIgnored private var minimum = 0.2
    @ObservationIgnored private var axisAnimationID: UUID?
    @ObservationIgnored private var destinationAxis: SplitWorkspaceAxis?
    @ObservationIgnored private var closingLayoutAccepted = false
#if DEBUG
    var diagnostic: String {
        "active=\(isActive),axisAnimation=\(String(describing: axisAnimationID)),rawRatio=\(rawRatio),pending=\(pending.sorted())"
    }
#endif

    func begin(model: AppShellModel, minimumRatio: Double) -> Bool {
        guard !isActive, let split = model.splitWorkspace, !model.previewContent.isPresented,
              let source = model.pane else { return false }
        let id = UUID()
        let panes = [source, model.splitPane].compactMap { $0 }
        for pane in panes {
            guard pane.scrollBridge.beginDividerResize(id: id, onComplete: { [weak self, weak pane] receipt in
                guard let self, let pane, self.token == receipt else { return }
                self.pending.remove(pane.conversationID)
                if self.pending.isEmpty { self.clear() }
            }) else {
                panes.forEach { $0.scrollBridge.invalidateDividerResize(id: id) }
                return false
            }
        }
        token = id
        arrangement = split
        participants = panes
        pending = Set(panes.map(\.conversationID))
        minimum = minimumRatio
        rawRatio = split.activeRatio
        closeIntent = nil
        isActive = true
        return true
    }

    func update(model: AppShellModel, displacement: Double, viewportHeight: Double) {
        guard axisAnimationID == nil, matches(model), let arrangement, viewportHeight.isFinite, viewportHeight > 0,
              displacement.isFinite else { return }
        rawRatio = arrangement.activeRatio + displacement / viewportHeight
        let candidate: SplitDropSlot? = rawRatio < minimum * 0.55 ? .top
            : (rawRatio > 1 - minimum * 0.55 ? .bottom : nil)
        // An empty picker cannot be promoted into a Single Conversation.
        closeIntent = candidate.flatMap { slot in
            slot == arrangement.sourceSlot && arrangement.secondaryConversationID == nil ? nil : slot
        }
        model.setSplitRatio(SplitWorkspaceGeometry.projectedRatio(rawRatio, minimum: minimum))
    }

    func finish(model: AppShellModel, cancelled: Bool) {
        guard matches(model), let arrangement else { invalidate(); return }
        if !cancelled, let closeIntent {
            close(model: model, keeping: closeIntent == .top ? .bottom : .top)
            return
        }
        if cancelled {
            axisAnimationID = nil
            destinationAxis = nil
            model.restoreSplitConfiguration(arrangement)
        } else {
            model.setSplitRatio(SplitWorkspaceGeometry.snappedRatio(rawRatio, minimum: minimum))
        }
        finishParticipants(revision: model.workspaceLayoutRevision)
    }

    func changeAxis(model: AppShellModel, to axis: SplitWorkspaceAxis) {
        guard model.splitWorkspace?.axis != axis, begin(model: model, minimumRatio: 0.2), let id = token else { return }
        let animation = UUID()
        axisAnimationID = animation
        destinationAxis = axis
        withAnimation(.easeOut(duration: 0.18), completionCriteria: .removed) {
            model.setSplitAxis(axis)
        } completion: { [weak self, weak model] in
            guard let self, self.token == id, self.axisAnimationID == animation else { return }
            guard let model, self.matches(model), model.splitWorkspace?.axis == axis else { self.invalidate(); return }
            model.refreshWorkspaceLayout()
            self.finishParticipants(revision: model.workspaceLayoutRevision)
        }
    }

    func close(model: AppShellModel, keeping slot: SplitDropSlot) {
        guard axisAnimationID == nil, let split = model.splitWorkspace else { return }
        if !isActive, !begin(model: model, minimumRatio: 0.2) { return }
        guard matches(model), let id = token,
              let survivor = slot == split.sourceSlot ? model.pane : model.splitPane else { invalidate(); return }
        for pane in participants where pane !== survivor {
            pane.scrollBridge.invalidateDividerResize(id: id)
            pending.remove(pane.conversationID)
        }
        participants = [survivor]
        isClosing = true
        withAnimation(.easeOut(duration: 0.18)) {
            model.closeSplit(keeping: slot)
        }
    }

    func nativeLayout(_ receipt: WorkspaceNativeLayoutReceipt?, context: WorkspaceLayoutContext?,
                      slot: WorkspaceSurfaceSlot, model: AppShellModel) {
        guard isClosing, !closingLayoutAccepted, token != nil, model.splitWorkspace == nil,
              slot == model.sourceSurfaceSlot, model.pane === participants.first,
              let receipt, let context, receipt.windowID == context.windowID,
              abs(receipt.frame.minX - context.frame.minX) <= 0.5,
              abs(receipt.frame.minY - context.frame.minY) <= 0.5,
              abs(receipt.frame.width - context.frame.width) <= 0.5,
              abs(receipt.frame.height - context.frame.height) <= 0.5 else { return }
        // Removing the Divider can leave SwiftUI's .removed animation completion
        // undelivered. The surviving native host proves the final Single bounds;
        // its measured reading acknowledgement still owns release of the lease.
        closingLayoutAccepted = true
        model.refreshWorkspaceLayout()
        finishParticipants(revision: model.workspaceLayoutRevision)
    }

    func adjust(model: AppShellModel, increment: Bool, minimumRatio: Double) {
        guard begin(model: model, minimumRatio: minimumRatio), let arrangement else { return }
        rawRatio = min(1 - minimumRatio, max(minimumRatio,
            arrangement.activeRatio + (increment ? 0.05 : -0.05)))
        model.setSplitRatio(rawRatio)
        finish(model: model, cancelled: false)
    }

    func matches(_ model: AppShellModel) -> Bool {
        guard let arrangement, let current = model.splitWorkspace else { return false }
        return current.arrangementID == arrangement.arrangementID
            && current.sourceConversationID == arrangement.sourceConversationID
            && current.secondaryConversationID == arrangement.secondaryConversationID
            && (current.axis == arrangement.axis || current.axis == destinationAxis)
    }

    func invalidate() {
        if let token { participants.forEach { $0.scrollBridge.invalidateDividerResize(id: token) } }
        clear()
    }

    func cancelForPresentationChange(model: AppShellModel) {
        guard let token else { return }
        if matches(model), let arrangement { model.restoreSplitConfiguration(arrangement) }
        // A hidden Pane cannot produce a final receipt. Cancel its lease and
        // enqueue ordinary restoration for its next measured presentation.
        participants.forEach { $0.scrollBridge.cancelDividerForPresentationChange(id: token) }
        clear()
    }

    private func finishParticipants(revision: UInt64) {
        guard let token else { return }
        closeIntent = nil
        participants.forEach { $0.scrollBridge.finishDividerResize(id: token, revision: revision) }
    }

    private func clear() {
        token = nil
        arrangement = nil
        participants = []
        pending = []
        closeIntent = nil
        isActive = false
        isClosing = false
        closingLayoutAccepted = false
        axisAnimationID = nil
        destinationAxis = nil
    }
}
