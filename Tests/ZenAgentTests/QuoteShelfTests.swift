import Foundation
import Testing

@testable import ZenAgent

@Suite("Quote shelf")
struct QuoteShelfTests {
    @Test("quoteShelfUsesSeparateFrameAndPreservesComposerReserves")
    func quoteShelfUsesSeparateFrameAndPreservesComposerReserves() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 800)
        let layout = ComposerGeometry.resolve(
            state: .resting,
            containerWidth: container.width,
            availableHeight: container.height,
            measuredTextHeight: 20,
            scaledLineHeight: 20,
            collapseProgress: .expanded
        )
        let shelf = QuoteShelfGeometry.resolve(
            layout: layout,
            container: container,
            measuredHeight: 48,
            isVisible: true
        )

        #expect(shelf != nil)
        #expect(shelf?.maxY == layout.visualFrame.minY)
        #expect(layout.leadingAccessoryReserve == ComposerGeometry.accessoryHitWidth)
        #expect(layout.trailingAccessoryReserve == ComposerGeometry.accessoryHitWidth)
        #expect(layout.controlRailReserve == 0)
        #expect(QuoteShelfGeometry.dropFrame(layout: layout, shelfFrame: shelf) == layout.visualFrame.union(shelf!))
        #expect(QuoteShelfGeometry.resolve(
            layout: layout,
            container: container,
            measuredHeight: 48,
            isVisible: false
        ) == nil)
    }
}
