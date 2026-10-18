import UIKit

enum AppSpaceGeometry {
    enum Item: Hashable, Sendable {
        case conversation(String)
        case newConversation
    }

    struct Placement: Equatable, Sendable {
        let item: Item
        let frame: CGRect
        let depth: Int
        let cornerRadius: CGFloat
    }

    struct Layout: Equatable, Sendable {
        let safeViewport: CGRect
        let logicalOrder: [Item]
        let cards: [Placement]
    }

    /// Leftward offset of each predecessor's center, as a fraction of the current card's
    /// width. Like the system app switcher, the first predecessor shows about half of
    /// itself and deeper cards compress toward the leading edge.
    static let depthOffsets: [CGFloat] = [0, 0.5, 0.78, 0.92]
    static let depthScaleStep: CGFloat = 0.035

    static func depthOffset(_ depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        if depth < depthOffsets.count { return depthOffsets[depth] }
        return depthOffsets[depthOffsets.count - 1] + 0.06 * CGFloat(depth - depthOffsets.count + 1)
    }

    /// The frame a predecessor occupies behind a current card at `base`.
    static func predecessorFrame(base: CGRect, depth: Int) -> CGRect {
        let scale = 1 - CGFloat(depth) * depthScaleStep
        let midX = base.midX - base.width * depthOffset(depth)
        return CGRect(x: midX - base.width * scale / 2, y: base.midY - base.height * scale / 2,
                      width: base.width * scale, height: base.height * scale)
    }

    static func resolve(size: CGSize, safeArea: UIEdgeInsets, historyIDs: [String],
                        current: Item, minimumCardSize: CGSize,
                        displayCornerRadius: CGFloat = 0) -> Layout? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              minimumCardSize.width.isFinite, minimumCardSize.height.isFinite,
              minimumCardSize.width > 0, minimumCardSize.height > 0,
              displayCornerRadius.isFinite, displayCornerRadius >= 0,
              [safeArea.top, safeArea.left, safeArea.bottom, safeArea.right].allSatisfy({ $0.isFinite && $0 >= 0 }),
              historyIDs.allSatisfy({ !$0.isEmpty }), Set(historyIDs).count == historyIDs.count
        else { return nil }
        let available = CGSize(width: size.width - safeArea.left - safeArea.right,
                               height: size.height - safeArea.top - safeArea.bottom)
        guard available.width.isFinite, available.height.isFinite,
              available.width > 0, available.height > 0 else { return nil }
        let safe = CGRect(origin: CGPoint(x: safeArea.left, y: safeArea.top), size: available)
        guard safe.maxX.isFinite, safe.maxY.isFinite else { return nil }
        let items = historyIDs.map(Item.conversation) + [.newConversation]
        guard let selected = items.firstIndex(of: current) else { return nil }

        // Calibration values, not immutable product dimensions. Cards keep the display's
        // own proportions, as app-switcher cards do, unless typography needs more room.
        let edgeX = min(16, available.width * 0.02)
        let edgeY = min(16, available.height * 0.04)
        let aspect = size.height / size.width
        let maxWidth = available.width - 2 * edgeX
        let maxHeight = min(available.height * 0.82, available.height - 2 * edgeY)
        var width = min(max(available.width * 0.7, minimumCardSize.width), maxWidth)
        var height = min(max(width * aspect, minimumCardSize.height), maxHeight)
        if height < width * aspect {
            width = min(max(height / aspect, minimumCardSize.width), maxWidth)
        }
        height = min(height, maxHeight)
        guard width > 0, height > 0 else { return nil }
        let centerX = min(safe.maxX - edgeX - width / 2,
                          max(safe.minX + edgeX + width / 2, safe.minX + available.width * 0.6))
        let frame = CGRect(x: centerX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        let count = min(selected, 3)
        // A real display corner makes every card concentric with the screen at its scale.
        let corner = displayCornerRadius > 0
            ? min(displayCornerRadius * width / size.width, min(width, height) / 2)
            : min(24, min(width, height) * 0.1)
        let cards = (0...count).reversed().map { depth in
            let scale = 1 - CGFloat(depth) * depthScaleStep
            return Placement(item: items[selected - depth],
                frame: depth == 0 ? frame : predecessorFrame(base: frame, depth: depth),
                depth: depth, cornerRadius: corner * scale)
        }
        guard safe.contains(frame), cards.allSatisfy({
            $0.frame.width > 0 && $0.frame.height > 0 && $0.cornerRadius.isFinite
                && [$0.frame.minX, $0.frame.minY, $0.frame.maxX, $0.frame.maxY].allSatisfy({ $0.isFinite })
                // Predecessors may slide past the leading edge, but each keeps a visible strip.
                && $0.frame.maxX > safe.minX && $0.frame.minY >= safe.minY && $0.frame.maxY <= safe.maxY
        }) else { return nil }
        return Layout(safeViewport: safe, logicalOrder: items, cards: cards)
    }
}
