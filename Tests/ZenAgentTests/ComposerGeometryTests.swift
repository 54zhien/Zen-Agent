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
        let hysteresisProgress = ComposerCollapseProgress(
            value: (ComposerPresentationReducer.compactExitThreshold
                + ComposerPresentationReducer.compactEnterThreshold) / 2
        )!
        let restingDuringHysteresis = layout(
            state: .resting,
            progress: hysteresisProgress
        )

        #expect(oneLine.leadingAccessoryReserve >= ComposerGeometry.accessoryHitWidth)
        #expect(oneLine.trailingAccessoryReserve >= ComposerGeometry.accessoryHitWidth)
        #expect(restingDuringHysteresis.leadingAccessoryReserve >= ComposerGeometry.accessoryHitWidth)
        #expect(restingDuringHysteresis.trailingAccessoryReserve >= ComposerGeometry.accessoryHitWidth)
        #expect(oneLine.previewLineLimit == 1)
        #expect(abs(oneLine.textFrame.midY - oneLine.outerFrame.midY) < 0.01)
        #expect(oneLine.outerHeight == longDraft.outerHeight)

        let shelf = QuoteShelfGeometry.resolve(
            layout: oneLine,
            container: CGRect(x: 0, y: 0, width: 390, height: 800),
            measuredHeight: 44,
            isVisible: true
        )
        #expect(shelf?.maxY == oneLine.visualFrame.minY)
        #expect(oneLine.leadingAccessoryReserve == ComposerGeometry.accessoryHitWidth)
        #expect(oneLine.trailingAccessoryReserve == ComposerGeometry.accessoryHitWidth)
        let editing = layout(state: .editing)
        #expect(oneLine.outerWidth < editing.outerWidth)
        #expect(oneLine.outerHeight < editing.outerHeight)
        #expect(oneLine.bottomSpacing < editing.bottomSpacing)
        #expect(oneLine.outerFrame.midX == editing.outerFrame.midX)
    }

    @Test("editingTextSpansAboveRailAndHeightCaps")
    func editingTextSpansAboveRailAndHeightCaps() {
        let shortDraft = layout(
            state: .editing,
            availableHeight: 600,
            measuredTextHeight: 22,
            scaledLineHeight: 22
        )
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

        #expect(shortDraft.outerHeight >= 108)
        #expect(shortDraft.textFrame.height >= 40)
        #expect(ComposerShapeToken.minimumRadius(for: shortDraft) < shortDraft.outerHeight / 2)
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
        let compactDuringHysteresis = layout(
            state: .compact,
            progress: ComposerCollapseProgress(
                value: (ComposerPresentationReducer.compactExitThreshold
                    + ComposerPresentationReducer.compactEnterThreshold) / 2
            )!
        )

        #expect(compact.outerWidth < resting.outerWidth)
        #expect(compact.outerHeight < resting.outerHeight)
        #expect(compact.fontScale < resting.fontScale)
        #expect(compact.padding.leading < resting.padding.leading)
        #expect(compact.leadingAccessoryReserve == 0)
        #expect(compact.trailingAccessoryReserve == 0)
        #expect(compact.controlRailReserve == 0)
        #expect(compactDuringHysteresis.leadingAccessoryReserve == 0)
        #expect(compactDuringHysteresis.trailingAccessoryReserve == 0)
        #expect(compactDuringHysteresis.controlRailReserve == 0)
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
        let scaled = layout(state: .resting, measuredTextHeight: 42, scaledLineHeight: 42)
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
        var previousRestingTextFrame: CGRect? = nil
        var previousCompactTextFrame: CGRect? = nil
        for step in 0...10 {
            let progress = ComposerCollapseProgress(value: Double(step) / 10)!
            let restingTarget = layout(state: .resting, progress: progress)
            let compactTarget = layout(state: .compact, progress: progress)

            #expect(restingTarget.outerWidth <= previousWidth + 0.01)
            #expect(restingTarget.outerHeight <= previousHeight + 0.01)
            #expect(restingTarget.fontScale <= previousFontScale + 0.01)
            #expect(abs(restingTarget.outerWidth - compactTarget.outerWidth) < 0.01)
            #expect(abs(restingTarget.outerHeight - compactTarget.outerHeight) < 0.01)

            if let previousRestingTextFrame {
                #expect(restingTarget.textFrame.width <= previousRestingTextFrame.width + 0.01)
                #expect(previousRestingTextFrame.width - restingTarget.textFrame.width < 10)
                #expect(restingTarget.textFrame.minX >= previousRestingTextFrame.minX - 0.01)
                #expect(restingTarget.textFrame.minX - previousRestingTextFrame.minX < 5)
                #expect(abs(restingTarget.textFrame.minY - previousRestingTextFrame.minY) < 1)
                #expect(abs(restingTarget.textFrame.height - previousRestingTextFrame.height) < 1)
            }
            if let previousCompactTextFrame {
                #expect(compactTarget.textFrame.width <= previousCompactTextFrame.width + 0.01)
                #expect(previousCompactTextFrame.width - compactTarget.textFrame.width < 10)
                #expect(compactTarget.textFrame.minX >= previousCompactTextFrame.minX - 0.01)
                #expect(compactTarget.textFrame.minX - previousCompactTextFrame.minX < 5)
                #expect(abs(compactTarget.textFrame.minY - previousCompactTextFrame.minY) < 1)
                #expect(abs(compactTarget.textFrame.height - previousCompactTextFrame.height) < 1)
            }

            previousWidth = restingTarget.outerWidth
            previousHeight = restingTarget.outerHeight
            previousFontScale = restingTarget.fontScale
            previousRestingTextFrame = restingTarget.textFrame
            previousCompactTextFrame = compactTarget.textFrame
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
        // Contract §4.3 makes reserves state-driven, so the two states have different text frames.
        #expect(beforeEnter.textFrame.width < afterEnter.textFrame.width)
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
