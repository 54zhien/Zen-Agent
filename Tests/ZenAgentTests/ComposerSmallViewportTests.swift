import Foundation
import Testing
@testable import ZenAgent

@Suite("Composer editing in a constrained Pane")
struct ComposerSmallViewportTests {
    @Test("a Pane with room for one line never clips its input to zero",
          arguments: [CGFloat(100), 146, 175, 180])
    func oneLineRemainsReadable(availableHeight: CGFloat) {
        let lineHeight: CGFloat = 22
        let layout = ComposerGeometry.resolve(state: .editing, containerWidth: 402,
            availableHeight: availableHeight, measuredTextHeight: lineHeight,
            scaledLineHeight: lineHeight, collapseProgress: ComposerCollapseProgress(value: 0)!)
        #expect(layout.textFrame.height >= lineHeight)
        #expect(layout.outerHeight + layout.bottomSpacing <= availableHeight)
        #expect(layout.textFrame.maxY <= layout.outerFrame.maxY)
        #expect(!layout.textAreaIsScrollable)
    }

    @Test("larger text retains one readable line while a long draft scrolls")
    func scaledInputKeepsItsViewport() {
        let lineHeight: CGFloat = 42
        let layout = ComposerGeometry.resolve(state: .editing, containerWidth: 402,
            availableHeight: 180, measuredTextHeight: 2_000,
            scaledLineHeight: lineHeight, collapseProgress: ComposerCollapseProgress(value: 0)!)
        #expect(layout.textFrame.height >= lineHeight)
        #expect(layout.outerHeight + layout.bottomSpacing <= 180)
        #expect(layout.textAreaIsScrollable)
    }
}
