import Foundation
import Observation

enum WorkspaceOverlayRoute: Hashable { case search, files, settings }

enum WorkspaceSidebarEligibility {
    static func allowsNativeInput(_ input: SurfaceLiftEligibility) -> Bool {
        // Stable editing is allowed. Lift's keyboard/editing policy is different.
        !input.hasMarkedText && !input.keyboardTransitioning && input.composerSettled
            && !input.selectionActive && !input.quoteDragActive && !input.overlayPresented
    }
}

@MainActor
@Observable
final class WorkspaceNavigationState {
    private(set) var progress = 0.0
    private(set) var isOpen = false
    private(set) var isDragging = false
    private(set) var overlay: WorkspaceOverlayRoute?
    private(set) var settlementID: UUID?
    private(set) var gestureID: UUID?
#if DEBUG
    @ObservationIgnored private var nativeEvents: [String] = []
    var nativeDiagnostic: String {
        "open=\(isOpen),progress=\(progress),drag=\(isDragging),settlement=\(String(describing: settlementID));events=\(nativeEvents.joined(separator: " | "))"
    }
    func recordNative(_ event: String) {
        nativeEvents.append(event)
        if nativeEvents.count > 12 { nativeEvents.removeFirst(nativeEvents.count - 12) }
    }
#endif
    var blocksLift: Bool { isDragging || progress > 0 || settlementID != nil || overlay != nil }

    @discardableResult
    func openSidebar(eligible: Bool) -> Bool {
        guard eligible, overlay == nil, !isDragging, settlementID == nil else { return false }
        isOpen = true; progress = 1
        settlementID = UUID()
        return true
    }

    func closeSidebar() {
        if progress > 0 || isOpen { settlementID = UUID() }
        isDragging = false; isOpen = false; progress = 0
        gestureID = nil
    }

    @discardableResult
    func begin(eligible: Bool) -> Bool {
        guard eligible, overlay == nil, !isDragging, settlementID == nil else { return false }
        isDragging = true
        gestureID = UUID()
        return true
    }

    func drag(displacement: Double, travel: Double) {
        guard isDragging else { return }
        guard displacement.isFinite, travel.isFinite, travel > 0 else {
            end(velocity: 0, travel: 1, cancelled: true)
            return
        }
        progress = min(1, max(0, (isOpen ? 1 : 0) + displacement / travel))
    }

    func end(velocity: Double, travel: Double, cancelled: Bool) {
        guard isDragging else { return }
        if !cancelled, velocity.isFinite, travel.isFinite, travel > 0 {
            isOpen = progress + velocity / travel * 0.12 >= 0.5
        }
        isDragging = false
        gestureID = nil
        progress = isOpen ? 1 : 0
        settlementID = UUID()
    }

    @discardableResult
    func present(_ route: WorkspaceOverlayRoute, available: Bool, eligible: Bool) -> Bool {
        guard available, eligible, isOpen, !isDragging, settlementID == nil, overlay == nil else { return false }
        closeSidebar()
        overlay = route
        return true
    }

    func completeSettlement(_ id: UUID) { if settlementID == id { settlementID = nil } }
    func dismissOverlay() { overlay = nil }
    func reset() { closeSidebar(); overlay = nil; settlementID = nil }
}
