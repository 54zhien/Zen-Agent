import Observation
import UIKit

struct WorkspaceNativeLayoutReceipt {
    let hostID: ObjectIdentifier
    let windowID: ObjectIdentifier
    let frame: CGRect
}

struct WorkspaceHeldPreview {
    let summary: ConversationSummary?
    let status: ConversationPreviewStatus
    let isNewEntry: Bool
    let label: String
}

/// Presentation only. AppShell commits logical ownership; the origin's native
/// driver animates. The existing target Pane is retained through its receipts.
@MainActor
@Observable
final class WorkspaceReturnPresentation {
    enum Phase { case prepared, awaitingTarget, animating, restoringOrigin }
    private(set) var plan: WorkspaceReturnPlan?
    private(set) var phase: Phase?
    private(set) var preview: WorkspaceHeldPreview?
    private(set) var receiptReady = false
    @ObservationIgnored private var token: UUID?
    @ObservationIgnored private var targetPane: ConversationPaneController?
    @ObservationIgnored private var targetHostID: ObjectIdentifier?
    @ObservationIgnored private var context: WorkspaceLayoutContext?
    @ObservationIgnored private var targetFrame: CGRect?
    @ObservationIgnored private var targetReceipt: WorkspaceNativeLayoutReceipt?
    @ObservationIgnored private var requestedRevision: UInt64?
    @ObservationIgnored private var animate: ((CGRect, @escaping (Bool) -> Void) -> Void)?
    @ObservationIgnored private var hideOrigin: (() -> Void)?
    @ObservationIgnored private var clearLabel: (() -> Void)?
    @ObservationIgnored private var interruptOrigin: (() -> Void)?
    @ObservationIgnored private weak var model: AppShellModel?

    var holdsPreview: Bool { plan?.holdsPreviewThroughReturn == true && phase != nil }
    func heldPreview(for slot: WorkspaceSurfaceSlot) -> WorkspaceHeldPreview? {
        holdsPreview && plan?.originSlot == slot ? preview : nil
    }
    func measuresTarget(_ slot: WorkspaceSurfaceSlot) -> Bool {
        holdsPreview && plan?.targetSurfaceSlot == slot && phase != .prepared
    }
    func suppressesTarget(_ slot: WorkspaceSurfaceSlot) -> Bool {
        measuresTarget(slot) && (phase == .awaitingTarget || phase == .animating)
    }
    func hidesOrigin(_ slot: WorkspaceSurfaceSlot) -> Bool {
        holdsPreview && plan?.originSlot == slot && phase == .restoringOrigin
    }

    func prepare(plan: WorkspaceReturnPlan, preview: WorkspaceHeldPreview,
                 pane: ConversationPaneController?, targetHostID: ObjectIdentifier?,
                 context: WorkspaceLayoutContext?, hideOrigin: @escaping () -> Void,
                 clearLabel: @escaping () -> Void, interruptOrigin: @escaping () -> Void) {
        clear()
        self.plan = plan
        self.preview = preview
        self.targetPane = pane
        self.targetHostID = targetHostID
        self.context = context
        self.hideOrigin = hideOrigin
        self.clearLabel = clearLabel
        self.interruptOrigin = interruptOrigin
        token = UUID()
        phase = .prepared
    }

    func validateOwnership(_ model: AppShellModel) -> Bool {
        guard holdsPreview, let plan, phase != .prepared, phase != .restoringOrigin else { return true }
        let current = model.splitWorkspace
        let target = plan.targetSurfaceSlot == model.sourceSurfaceSlot ? model.pane : model.splitPane
        guard current?.arrangementID == plan.arrangement?.arrangementID,
              current?.sourceConversationID == plan.arrangement?.sourceConversationID,
              current?.secondaryConversationID == plan.arrangement?.secondaryConversationID,
              target === targetPane else {
            interruptOrigin?()
            return false
        }
        return true
    }

    func begin(commit: () -> Bool, animate: @escaping (CGRect, @escaping (Bool) -> Void) -> Void) -> Bool? {
        guard holdsPreview else { return nil }
        guard phase == .prepared, targetPane != nil, targetHostID != nil,
              let context, let frame = plan?.destination(in: context.frame, safeArea: .zero) else { clear(); return false }
        targetFrame = frame
        self.animate = animate
        // Publish the retained descriptor and mount policy before commit clears Browse.
        phase = .awaitingTarget
        guard commit() else { clear(); return false }
        return true
    }

    func nativeLayout(_ receipt: WorkspaceNativeLayoutReceipt?, slot: WorkspaceSurfaceSlot,
                      currentContext: WorkspaceLayoutContext?, model: AppShellModel,
                      visibilityRevision: UInt64) {
        guard holdsPreview, let plan else { return }
        self.model = model
        guard validateOwnership(model) else { return }
        guard let receipt else { if slot == plan.originSlot || slot == plan.targetSurfaceSlot { abort() }; return }
        if phase == .restoringOrigin, slot == plan.originSlot {
            guard let currentContext else { return }
            let policy = WorkspaceDevicePresentation.resolve(isPad: currentContext.isPad,
                size: currentContext.windowSize, split: model.splitWorkspace)
            let restored = WorkspaceReturnPlan.resolve(split: model.splitWorkspace,
                sourceSurfaceSlot: model.sourceSurfaceSlot, originSlot: slot,
                selectedID: nil, presentation: policy)
            guard let frame = restored.destination(in: currentContext.frame, safeArea: .zero),
                  receipt.windowID == currentContext.windowID, Self.matches(receipt.frame, frame) else { return }
            clear()
            return
        }
        guard phase == .awaitingTarget, slot == plan.targetSurfaceSlot else { return }
        targetReceipt = receipt
        guard receipt.hostID == targetHostID, receipt.windowID == context?.windowID,
              let targetFrame, Self.matches(receipt.frame, targetFrame) else {
            if let token { targetPane?.scrollBridge.cancelReturnLayout(id: token) }
            requestedRevision = nil
            receiptReady = false
            return
        }
        guard
              receipt.hostID == targetHostID, receipt.windowID == context?.windowID,
              let token, let targetPane else { return }
        guard requestedRevision == nil else { return }
        let revision = model.workspaceLayoutRevision + 1
        requestedRevision = revision
        targetPane.scrollBridge.awaitReturnLayout(id: token, revision: revision,
            visibilityRevision: visibilityRevision, onInvalidation: { [weak self] id in
                guard let self, self.token == id, self.phase == .awaitingTarget else { return }
                self.interruptOrigin?()
            }) { [weak self] id in
                guard let self, self.token == id, self.phase == .awaitingTarget,
                      let actual = self.targetReceipt, let expected = self.targetFrame,
                      actual.hostID == self.targetHostID, actual.windowID == self.context?.windowID,
                      Self.matches(actual.frame, expected) else { return }
                self.receiptReady = true
#if DEBUG
                if ProcessInfo.processInfo.environment["ZEN_RETURN_RECEIPT_PAUSE_UI_TEST"] == "1" { return }
#endif
                self.resume()
            }
        model.refreshWorkspaceLayout()
    }

    func resume() {
        if let model, !validateOwnership(model) { return }
        guard phase == .awaitingTarget, receiptReady, let frame = targetFrame,
              let animate, let token else { return }
        phase = .animating
        animate(frame) { [weak self] _ in
            guard let self, self.token == token else { return }
            // The native driver hides the proxy before resetting its transform.
            self.phase = .restoringOrigin
            self.receiptReady = false
        }
    }

    func cancel() {
        guard phase != nil else { return }
        if phase == .prepared { clear(); return }
        hideOrigin?()
        phase = .restoringOrigin
        receiptReady = false
        if let token { targetPane?.scrollBridge.cancelReturnLayout(id: token) }
        animate = nil
    }

    func abort() { hideOrigin?(); clear() }

    private func clear() {
        if let token { targetPane?.scrollBridge.cancelReturnLayout(id: token) }
        clearLabel?()
        phase = nil; plan = nil; preview = nil; receiptReady = false
        token = nil; targetPane = nil; targetHostID = nil; context = nil
        targetFrame = nil; targetReceipt = nil; requestedRevision = nil
        animate = nil; hideOrigin = nil; clearLabel = nil
        interruptOrigin = nil; model = nil
    }

    private static func matches(_ actual: CGRect, _ expected: CGRect) -> Bool {
        [actual.minX, actual.minY, actual.width, actual.height].allSatisfy(\.isFinite)
            && abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1
            && abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1
    }
}
