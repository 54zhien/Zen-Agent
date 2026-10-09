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

    static func resolve(size: CGSize, safeArea: UIEdgeInsets, historyIDs: [String],
                        current: Item, minimumCardSize: CGSize) -> Layout? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              minimumCardSize.width.isFinite, minimumCardSize.height.isFinite,
              minimumCardSize.width > 0, minimumCardSize.height > 0,
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

        // Blueprint calibration values, not immutable product dimensions. Asymmetric
        // breathing room retains a right bias even when typography needs a wider card.
        let edgeX = min(16, available.width * 0.02)
        let edgeY = min(16, available.height * 0.04)
        let width = min(max(available.width * 0.82, minimumCardSize.width), available.width - 3 * edgeX)
        let height = min(max(available.height * 0.74, minimumCardSize.height), available.height - 2 * edgeY)
        let centerX = min(safe.maxX - edgeX - width / 2,
                          max(safe.minX + 2 * edgeX + width / 2, safe.minX + available.width * 0.56))
        let frame = CGRect(x: centerX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        let count = min(selected, 3)
        // Keep a positive rounding margin instead of relying on exact edge equality.
        let marginX = min(1, available.width * 0.001)
        let stepX = count == 0 ? 0 : max(0, min(28, (frame.minX - safe.minX - marginX) / CGFloat(count)))
        let corner = min(24, min(width, height) * 0.1)
        let cards = (0...count).reversed().map { depth in
            let scale = 1 - CGFloat(depth) * 0.04
            return Placement(item: items[selected - depth],
                frame: CGRect(x: frame.minX - stepX * CGFloat(depth), y: frame.midY - height * scale / 2,
                              width: width * scale, height: height * scale),
                depth: depth, cornerRadius: corner * scale)
        }
        guard cards.allSatisfy({
            $0.frame.width > 0 && $0.frame.height > 0 && $0.cornerRadius.isFinite
                && [$0.frame.minX, $0.frame.minY, $0.frame.maxX, $0.frame.maxY].allSatisfy({ $0.isFinite })
                && safe.contains($0.frame)
        }) else { return nil }
        return Layout(safeViewport: safe, logicalOrder: items, cards: cards)
    }
}
