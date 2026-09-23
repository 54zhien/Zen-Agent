import SwiftUI

enum QuoteShelfGeometry {
    static func resolve(
        layout: ComposerLayout,
        container: CGRect,
        measuredHeight: CGFloat,
        isVisible: Bool
    ) -> CGRect? {
        guard isVisible,
              measuredHeight.isFinite,
              measuredHeight > 0,
              layout.visualFrame.width > 0
        else { return nil }

        let frame = CGRect(
            x: layout.visualFrame.minX,
            y: layout.visualFrame.minY - measuredHeight,
            width: layout.visualFrame.width,
            height: measuredHeight
        )
        guard frame.minY >= container.minY,
              frame.maxY <= layout.visualFrame.minY,
              frame.minX >= container.minX,
              frame.maxX <= container.maxX
        else { return nil }
        return frame
    }

    static func dropFrame(layout: ComposerLayout, shelfFrame: CGRect?) -> CGRect {
        guard let shelfFrame else { return layout.visualFrame }
        return layout.visualFrame.union(shelfFrame)
    }
}
