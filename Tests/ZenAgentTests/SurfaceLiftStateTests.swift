import Foundation
import Testing
@testable import ZenAgent

@Suite("Surface Lift presentation state")
struct SurfaceLiftStateTests {
    @Test func longPressOnlyArmsAndReleaseStaysFull() {
        var state = SurfaceLiftState()
        #expect(state.arm(SurfaceLiftEligibility()))
        #expect(state.phase == .armed)
        #expect(state.progress == 0)
        #expect(!state.arm(SurfaceLiftEligibility()))
        #expect(state.end() == nil)
        #expect(state.phase == .full && state.progress == 0)
    }

    @Test func dragOnsetDirectionBacktrackAndCommit() throws {
        var state = SurfaceLiftState()
        #expect(state.arm(SurfaceLiftEligibility()))
        #expect(state.drag(upwardDistance: -40, eligibility: SurfaceLiftEligibility()))
        #expect(state.phase == .armed && state.progress == 0)
        #expect(state.drag(upwardDistance: 11, eligibility: SurfaceLiftEligibility()))
        #expect(state.phase == .armed)
        #expect(state.drag(upwardDistance: 96, eligibility: SurfaceLiftEligibility()))
        #expect(state.phase == .lifting && state.progress == 0.5)
        #expect(state.drag(upwardDistance: 40, eligibility: SurfaceLiftEligibility()))
        #expect(abs(state.progress - 1.0 / 6.0) < 0.000001)
        #expect(state.drag(upwardDistance: 300, eligibility: SurfaceLiftEligibility()))
        #expect(state.progress == 1)
        let settle = try #require(state.end())
        #expect(settle.destination == .card && settle.startProgress == 1)
        #expect(state.phase == .settling)
        #expect(state.complete(settle, finished: true))
        #expect(state.phase == .card && state.progress == 1)
    }

    @Test(arguments: [false, true])
    func cancellationOrShortDragReturnsFull(cancelled: Bool) throws {
        var state = SurfaceLiftState()
        #expect(state.arm(SurfaceLiftEligibility()))
        #expect(state.drag(upwardDistance: cancelled ? 180 : 40, eligibility: SurfaceLiftEligibility()))
        let settle = try #require(state.end(cancelled: cancelled))
        #expect(settle.destination == .full)
        #expect(state.complete(settle, finished: true))
        #expect(state.phase == .full && state.progress == 0)
    }

    @Test func everyUnsafeInputBlocksArmingAndInterruptsDrag() {
        var inputs = [SurfaceLiftEligibility]()
        var editing = SurfaceLiftEligibility(); editing.isEditing = true; inputs.append(editing)
        var composing = SurfaceLiftEligibility(); composing.hasMarkedText = true; inputs.append(composing)
        var visible = SurfaceLiftEligibility(); visible.keyboardVisible = true; inputs.append(visible)
        var changing = SurfaceLiftEligibility(); changing.keyboardTransitioning = true; inputs.append(changing)
        var moving = SurfaceLiftEligibility(); moving.composerSettled = false; inputs.append(moving)
        var selected = SurfaceLiftEligibility(); selected.selectionActive = true; inputs.append(selected)
        var quote = SurfaceLiftEligibility(); quote.quoteDragActive = true; inputs.append(quote)
        var overlay = SurfaceLiftEligibility(); overlay.overlayPresented = true; inputs.append(overlay)
        for input in inputs {
            var state = SurfaceLiftState()
            #expect(!input.allowsLift)
            #expect(!state.arm(input))
            #expect(state.phase == .full && state.progress == 0)
            #expect(state.arm(SurfaceLiftEligibility()))
            #expect(state.drag(upwardDistance: 96, eligibility: SurfaceLiftEligibility()))
            #expect(!state.drag(upwardDistance: 110, eligibility: input))
            #expect(state.phase == .full && state.progress == 0)
        }
    }

    @Test func invalidMotionCannotCorruptState() {
        var state = SurfaceLiftState()
        #expect(!state.drag(upwardDistance: 96, eligibility: SurfaceLiftEligibility()))
        #expect(state.arm(SurfaceLiftEligibility()))
        #expect(state.drag(upwardDistance: 96, eligibility: SurfaceLiftEligibility()))
        let before = state
        #expect(!state.drag(upwardDistance: .nan, eligibility: SurfaceLiftEligibility()))
        #expect(!state.drag(upwardDistance: .infinity, eligibility: SurfaceLiftEligibility()))
        #expect(state == before)
        #expect(state.requestReturn(visibleProgress: .nan) == nil)
        #expect(state == before)
    }

    @Test func returnUsesVisibleProgressAndRejectsLateCompletion() throws {
        var state = SurfaceLiftState()
        #expect(state.arm(SurfaceLiftEligibility()))
        #expect(state.drag(upwardDistance: 130, eligibility: SurfaceLiftEligibility()))
        let old = try #require(state.end())
        let returning = try #require(state.requestReturn(visibleProgress: 0.8))
        #expect(returning.destination == .full && returning.startProgress == 0.8)
        #expect(returning.identity != old.identity)
        let before = state
        #expect(!state.complete(old, finished: true))
        #expect(state == before)
        #expect(state.complete(returning, finished: true))
        #expect(state.phase == .full && state.progress == 0)
        #expect(state.arm(SurfaceLiftEligibility()))
        #expect(!state.complete(returning, finished: true))
        #expect(state.phase == .armed)
    }

    @Test func interruptAndUnfinishedCompletionCannotLeaveStuckPresentation() throws {
        var state = SurfaceLiftState()
        #expect(state.arm(SurfaceLiftEligibility()))
        #expect(state.drag(upwardDistance: 180, eligibility: SurfaceLiftEligibility()))
        let old = try #require(state.end())
        state.interrupt()
        #expect(!state.complete(old, finished: true))
        #expect(state.phase == .full && state.pendingSettlement == nil)
        #expect(state.arm(SurfaceLiftEligibility()))
        #expect(state.drag(upwardDistance: 180, eligibility: SurfaceLiftEligibility()))
        let next = try #require(state.end())
        #expect(state.complete(next, finished: false))
        #expect(state.phase == .full && state.progress == 0 && state.pendingSettlement == nil)
    }
}
