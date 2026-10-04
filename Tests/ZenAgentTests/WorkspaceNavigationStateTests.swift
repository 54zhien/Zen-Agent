import Testing
@testable import ZenAgent

@Suite("Sidebar navigation ownership")
@MainActor
struct WorkspaceNavigationStateTests {
    @Test func cancellationRestoresEachStableEndpointAndReleaseSamplesFinalDisplacement() {
        let state = WorkspaceNavigationState()
        #expect(!state.begin(eligible: false))
        #expect(state.begin(eligible: true))
        state.drag(displacement: 45, travel: 60)
        #expect(state.progress == 0.75)
        state.end(velocity: 0, travel: 60, cancelled: true)
        #expect(state.progress == 0 && !state.isOpen && !state.isDragging)
        settle(state)
        #expect(state.openSidebar(eligible: true))
        settle(state)
        #expect(state.begin(eligible: true))
        state.drag(displacement: -50, travel: 60)
        state.end(velocity: 0, travel: 60, cancelled: true)
        #expect(state.isOpen && state.progress == 1)
        settle(state)
        #expect(state.begin(eligible: true))
        state.drag(displacement: -15, travel: 60)
        state.drag(displacement: -60, travel: 60)
        state.end(velocity: 0, travel: 60, cancelled: false)
        #expect(!state.isOpen && state.progress == 0)
    }

    @Test func unavailableRoutesDoNotCreateAnEmptyOverlayAndOwnerLossClearsEverything() {
        let state = WorkspaceNavigationState()
        #expect(state.openSidebar(eligible: true))
        settle(state)
        #expect(!state.present(.search, available: false, eligible: true))
        #expect(state.isOpen && state.overlay == nil)
        #expect(!state.present(.search, available: true, eligible: false))
        #expect(state.present(.search, available: true, eligible: true))
        #expect(!state.isOpen && state.overlay == .search)
        #expect(!state.openSidebar(eligible: true))
        state.reset()
        #expect(state.overlay == nil && state.progress == 0 && !state.isDragging)
    }

    @Test func invalidGeometryCannotPublishNonfinitePresentation() {
        let state = WorkspaceNavigationState()
        #expect(state.begin(eligible: true))
        state.drag(displacement: .nan, travel: 60)
        #expect(state.progress == 0 && !state.isDragging)
        settle(state)
        #expect(state.openSidebar(eligible: true))
        settle(state)
        #expect(state.begin(eligible: true))
        state.drag(displacement: -20, travel: 0)
        #expect(state.progress == 1 && !state.isDragging)
    }

    @Test func stableEditingIsAllowedButNativeCompositionAndSelectionAreNot() {
        var input = SurfaceLiftEligibility(isEditing: true, keyboardVisible: true)
        #expect(WorkspaceSidebarEligibility.allowsNativeInput(input))
        input.hasMarkedText = true
        #expect(!WorkspaceSidebarEligibility.allowsNativeInput(input))
        input.hasMarkedText = false; input.selectionActive = true
        #expect(!WorkspaceSidebarEligibility.allowsNativeInput(input))
        input.selectionActive = false; input.keyboardTransitioning = true
        #expect(!WorkspaceSidebarEligibility.allowsNativeInput(input))
        input.keyboardTransitioning = false; input.quoteDragActive = true
        #expect(!WorkspaceSidebarEligibility.allowsNativeInput(input))
        input.quoteDragActive = false; input.composerSettled = false
        #expect(!WorkspaceSidebarEligibility.allowsNativeInput(input))
    }

    @Test func staleNativeCompletionCannotReleaseANewerNavigationSettlement() throws {
        let state = WorkspaceNavigationState()
        #expect(state.openSidebar(eligible: true))
        let old = try #require(state.settlementID)
        state.closeSidebar()
        let current = try #require(state.settlementID)
        #expect(old != current && state.blocksLift)
        state.completeSettlement(old)
        #expect(state.blocksLift && state.settlementID == current)
        state.completeSettlement(current)
        #expect(!state.blocksLift)
    }

    private func settle(_ state: WorkspaceNavigationState) {
        if let id = state.settlementID { state.completeSettlement(id) }
    }

    @Test func ownerLossInvalidatesTheOldGestureBeforeANewOneBegins() throws {
        let state = WorkspaceNavigationState()
        #expect(state.begin(eligible: true))
        let old = try #require(state.gestureID)
        state.reset()
        #expect(state.gestureID == nil)
        #expect(state.begin(eligible: true))
        #expect(state.gestureID != old)
        state.end(velocity: 0, travel: 60, cancelled: true)
        #expect(state.gestureID == nil)
    }
}
