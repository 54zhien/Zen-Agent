import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer context action")
struct ComposerContextActionTests {
    @Test("idleAndTerminalProjectionChooseSameAction")
    func idleAndTerminalProjectionChooseSameAction() {
        let idle = resolve(projection: nil, sendable: true)
        let terminal = resolve(
            projection: RunProjection(runID: "terminal-run", state: .completed),
            sendable: true
        )

        #expect(idle == terminal)
        #expect(idle.primary == .send(enabled: true))
    }

    @Test("activeRunOverridesSendIncludingSuspended")
    func activeRunOverridesSendIncludingSuspended() {
        let state = resolve(
            projection: RunProjection(runID: "suspended-run", state: .suspended),
            sendable: true
        )

        #expect(state.primary == .stop(runID: "suspended-run", enabled: true))
        #expect(state.voiceTarget == .trailingAdjacentLeading)
        #expect(!state.showsVoice)
    }

    @Test("stoppingKeepsDisabledStopVisible")
    func stoppingKeepsDisabledStopVisible() {
        let state = resolve(
            projection: RunProjection(runID: "stopping-run", state: .stopping),
            sendable: true
        )

        #expect(state.primary == .stop(runID: "stopping-run", enabled: false))
        #expect(state.voiceTarget == .trailingAdjacentLeading)
    }

    @Test("compactSuppressesEveryAction")
    func compactSuppressesEveryAction() {
        let layout = layout(state: .compact)
        let state = resolve(
            projection: RunProjection(runID: "active-run", state: .streaming),
            presentationState: .compact,
            sendable: true,
            plusAvailable: true
        )

        #expect(!state.showsPlus)
        #expect(!state.showsVoice)
        #expect(ComposerContextAction.leadingPlusFrame(layout: layout, state: .compact) == nil)
        #expect(ComposerContextAction.trailingFrame(layout: layout, state: .compact) == nil)
    }

    @Test("rightSlotFrameStaysFixedAndVoiceTargetMovesLeft")
    func rightSlotFrameStaysFixedAndVoiceTargetMovesLeft() {
        let restingLayout = layout(state: .resting)
        let noPrimary = resolve(sendable: false)
        let withSend = resolve(sendable: true)
        let idleFrame = ComposerContextAction.trailingFrame(
            layout: restingLayout,
            state: .resting
        )
        let sendFrame = ComposerContextAction.trailingFrame(
            layout: restingLayout,
            state: .resting
        )
        let plusFrame = ComposerContextAction.leadingPlusFrame(
            layout: restingLayout,
            state: .resting
        )

        #expect(idleFrame == sendFrame)
        #expect(noPrimary.voiceTarget == .trailing)
        #expect(withSend.voiceTarget == .trailingAdjacentLeading)
        #expect(!noPrimary.showsVoice && !withSend.showsVoice)
        #expect(plusFrame.map { !restingLayout.textFrame.intersects($0) } == true)
        #expect(idleFrame.map { !restingLayout.textFrame.intersects($0) } == true)

        let editingLayout = layout(state: .editing)
        let editingTrailing = ComposerContextAction.trailingFrame(
            layout: editingLayout,
            state: .editing
        )
        let editingPlus = ComposerContextAction.leadingPlusFrame(
            layout: editingLayout,
            state: .editing
        )
        let radius = ComposerShapeToken.minimumRadius(for: editingLayout)
        #expect(editingTrailing?.width == ComposerGeometry.accessoryHitWidth)
        #expect(editingTrailing?.midX == editingLayout.outerFrame.maxX - radius)
        #expect(editingTrailing.map { !editingLayout.textFrame.intersects($0) } == true)
        #expect(editingPlus?.midX == editingLayout.outerFrame.minX + radius)
        #expect(editingPlus?.midY == editingLayout.outerFrame.maxY - radius)
        #expect(editingPlus.map { !editingLayout.textFrame.intersects($0) } == true)
    }

    private func resolve(
        projection: RunProjection? = nil,
        presentationState: ComposerPresentationState = .resting,
        sendable: Bool,
        plusAvailable: Bool = false,
        submission: ComposerSubmissionState = .idle
    ) -> ComposerContextActionState {
        ComposerContextAction.resolve(
            projection: projection,
            presentationState: presentationState,
            sendable: sendable,
            hasDraft: sendable,
            plusAvailable: plusAvailable,
            submission: submission
        )
    }

    private func layout(state: ComposerPresentationState) -> ComposerLayout {
        ComposerGeometry.resolve(
            state: state,
            containerWidth: 390,
            availableHeight: 800,
            measuredTextHeight: 22,
            scaledLineHeight: 22,
            collapseProgress: state == .compact ? .fullyCollapsed : .expanded
        )
    }
}
