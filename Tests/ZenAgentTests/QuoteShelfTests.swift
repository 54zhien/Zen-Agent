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

    @Test("quoteDropFrameCoversComposerAndVisibleShelf")
    func quoteDropFrameCoversComposerAndVisibleShelf() {
        let container = CGRect(x: 0, y: 0, width: 390, height: 800)
        let layout = ComposerGeometry.resolve(
            state: .resting,
            containerWidth: container.width,
            availableHeight: container.height,
            measuredTextHeight: 20,
            scaledLineHeight: 20,
            collapseProgress: .expanded
        )
        let shelfFrame = QuoteShelfGeometry.resolve(
            layout: layout,
            container: container,
            measuredHeight: 48,
            isVisible: true
        )!
        let dropFrame = QuoteShelfGeometry.dropFrame(layout: layout, shelfFrame: shelfFrame)

        assertCorners(of: layout.visualFrame, areCoveredBy: dropFrame)
        assertCorners(of: shelfFrame, areCoveredBy: dropFrame)
        #expect(QuoteShelfGeometry.dropFrame(layout: layout, shelfFrame: nil) == layout.visualFrame)
    }

    private func assertCorners(of frame: CGRect, areCoveredBy container: CGRect) {
        let corners = [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.minX, y: frame.maxY),
            CGPoint(x: frame.maxX, y: frame.maxY)
        ]

        for corner in corners {
            // CGRect.contains excludes max edges, so move boundary coordinates one representable step inward.
            let x = corner.x == container.maxX ? corner.x.nextDown : corner.x
            let y = corner.y == container.maxY ? corner.y.nextDown : corner.y
            #expect(container.contains(CGPoint(x: x, y: y)))
        }
    }
}
