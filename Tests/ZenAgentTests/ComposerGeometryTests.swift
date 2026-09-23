import Foundation
import Testing

@testable import ZenAgent

@Suite("Composer geometry")
struct ComposerGeometryTests {
    @Test("restingReservesAccessoriesAndCentersSingleLine")
    func restingReservesAccessoriesAndCentersSingleLine() {
        let oneLine = layout(
            state: .resting,
            measuredTextHeight: 22,
            scaledLineHeight: 22
        )
        let longDraft = layout(
            state: .resting,
            measuredTextHeight: 2_000,
            scaledLineHeight: 22
        )

        #expect(oneLine.leadingAccessoryReserve >= ComposerGeometry.accessoryHitWidth)
        #expect(oneLine.trailingAccessoryReserve >= ComposerGeometry.accessoryHitWidth)
        #expect(oneLine.previewLineLimit == 1)
        #expect(abs(oneLine.textFrame.midY - oneLine.outerFrame.midY) < 0.01)
        #expect(oneLine.outerHeight == longDraft.outerHeight)
    }

    @Test("editingTextSpansAboveRailAndHeightCaps")
    func editingTextSpansAboveRailAndHeightCaps() {
        let contentSized = layout(
            state: .editing,
            availableHeight: 600,
            measuredTextHeight: 80,
            scaledLineHeight: 22
        )
        let capped = layout(
            state: .editing,
            availableHeight: 600,
            measuredTextHeight: 2_000,
            scaledLineHeight: 22
        )

        #expect(contentSized.controlRailReserve >= ComposerGeometry.controlRailMinHeight)
        #expect(abs(contentSized.textFrame.minY - contentSized.outerFrame.minY - ComposerGeometry.editorTopInset) < 0.01)
        #expect(abs(contentSized.textFrame.maxY - contentSized.outerFrame.maxY + contentSized.controlRailReserve) < 0.01)
        #expect(!contentSized.textAreaIsScrollable)
        #expect(capped.outerHeight <= 600 * ComposerGeometry.editingMaxHeightFraction + 0.01)
        #expect(abs(capped.outerHeight - 600 * ComposerGeometry.editingMaxHeightFraction) < 0.01)
        #expect(capped.textAreaIsScrollable)
    }

    @Test("compactShrinksWithoutAccessoryReserves")
    func compactShrinksWithoutAccessoryReserves() {
        let resting = layout(state: .resting)
        let compact = layout(
            state: .compact,
            progress: .fullyCollapsed
        )

        #expect(compact.outerWidth < resting.outerWidth)
        #expect(compact.outerHeight < resting.outerHeight)
        #expect(compact.fontScale < resting.fontScale)
        #expect(compact.padding.leading < resting.padding.leading)
        #expect(compact.leadingAccessoryReserve == 0)
        #expect(compact.trailingAccessoryReserve == 0)
        #expect(compact.controlRailReserve == 0)
    }

    @Test("compactHitFrameRemainsReliable")
    func compactHitFrameRemainsReliable() {
        let compact = layout(state: .compact, progress: .fullyCollapsed)

        #expect(compact.hitFrame.width >= ComposerGeometry.reliableHitSize)
        #expect(compact.hitFrame.height >= ComposerGeometry.reliableHitSize)
        #expect(compact.hitFrame != compact.visualFrame)
        #expect(compact.hitFrame.minX <= compact.visualFrame.minX)
        #expect(compact.hitFrame.maxX >= compact.visualFrame.maxX)
        #expect(compact.hitFrame.minY <= compact.visualFrame.minY)
        #expect(compact.hitFrame.maxY >= compact.visualFrame.maxY)
    }

    @Test("geometryRespondsToWidthHeightAndScaledText")
    func geometryRespondsToWidthHeightAndScaledText() {
        let narrow = layout(state: .resting, containerWidth: 180)
        let standard = layout(state: .resting)
        let scaled = layout(state: .resting, scaledLineHeight: 42, measuredTextHeight: 42)
        let constrained = layout(
            state: .editing,
            availableHeight: 180,
            measuredTextHeight: 1_000
        )

        #expect(narrow.outerWidth <= 180 - 2 * ComposerGeometry.edgeInset)
        #expect(narrow.textFrame.width >= 0)
        #expect(scaled.outerHeight > standard.outerHeight)
        #expect(constrained.outerHeight <= 180 * ComposerGeometry.editingMaxHeightFraction + 0.01)
        #expect(constrained.textAreaIsScrollable)

        var previousWidth = CGFloat.greatestFiniteMagnitude
        var previousHeight = CGFloat.greatestFiniteMagnitude
        var previousFontScale = CGFloat.greatestFiniteMagnitude
        for step in 0...10 {
            let progress = ComposerCollapseProgress(value: Double(step) / 10)!
            let restingTarget = layout(state: .resting, progress: progress)
            let compactTarget = layout(state: .compact, progress: progress)

            #expect(restingTarget.outerWidth <= previousWidth + 0.01)
            #expect(restingTarget.outerHeight <= previousHeight + 0.01)
            #expect(restingTarget.fontScale <= previousFontScale + 0.01)
            #expect(abs(restingTarget.outerWidth - compactTarget.outerWidth) < 0.01)
            #expect(abs(restingTarget.outerHeight - compactTarget.outerHeight) < 0.01)
            #expect(abs(restingTarget.textFrame.width - compactTarget.textFrame.width) < 0.01)

            previousWidth = restingTarget.outerWidth
            previousHeight = restingTarget.outerHeight
            previousFontScale = restingTarget.fontScale
        }

        let beforeEnter = layout(
            state: .resting,
            progress: ComposerCollapseProgress(value: ComposerPresentationReducer.compactEnterThreshold)!
        )
        let afterEnter = layout(
            state: .compact,
            progress: ComposerCollapseProgress(value: ComposerPresentationReducer.compactEnterThreshold)!
        )
        #expect(beforeEnter.outerFrame == afterEnter.outerFrame)
        #expect(beforeEnter.textFrame == afterEnter.textFrame)
    }

    private func layout(
        state: ComposerPresentationState,
        containerWidth: CGFloat = 390,
        availableHeight: CGFloat = 800,
        measuredTextHeight: CGFloat = 22,
        scaledLineHeight: CGFloat = 22,
        progress: ComposerCollapseProgress = .expanded
    ) -> ComposerLayout {
        ComposerGeometry.resolve(
            state: state,
            containerWidth: containerWidth,
            availableHeight: availableHeight,
            measuredTextHeight: measuredTextHeight,
            scaledLineHeight: scaledLineHeight,
            collapseProgress: progress
        )
    }
}
