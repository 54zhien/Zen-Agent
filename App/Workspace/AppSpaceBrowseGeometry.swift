import UIKit

enum AppSpaceBrowseGeometry {
    struct Card: Equatable, Sendable {
        let item: AppSpaceGeometry.Item
        let frame: CGRect
        let cornerRadius: CGFloat
        let opacity: Double
        let depth: Double
    }
    struct Layout: Equatable, Sendable {
        let cards: [Card]
        let travel: CGFloat
    }
    static func resolve(size: CGSize, safeArea: UIEdgeInsets, historyIDs: [String],
                        current: AppSpaceGeometry.Item, offset: Double,
                        minimumCardSize: CGSize, includesNew: Bool = false,
                        displayCornerRadius: CGFloat = 0) -> Layout? {
        guard offset.isFinite, abs(offset) <= 1, historyIDs.count <= 5,
              let resting = AppSpaceGeometry.resolve(size: size, safeArea: safeArea,
                historyIDs: historyIDs, current: current, minimumCardSize: minimumCardSize,
                displayCornerRadius: displayCornerRadius),
              let base = resting.cards.first(where: { $0.item == current }) else { return nil }
        let items = historyIDs.map(AppSpaceGeometry.Item.conversation)
            + (includesNew || current == .newConversation ? [.newConversation] : [])
        guard items.count <= 5, let selected = items.firstIndex(of: current) else { return nil }
        let travel = size.width - base.frame.minX + 16
        guard travel.isFinite, travel > 0 else { return nil }
        let targetIndex = selected + (offset > 0 ? -1 : offset < 0 ? 1 : 0)
        let target = items.indices.contains(targetIndex) ? targetIndex : selected

        let cards = items.enumerated().map { index, item in
            let depth = Double(selected - index) - (target == selected ? 0 : offset)
            let center = interpolateDepth(depth) { level in
                level <= 0 ? base.frame.midX - CGFloat(level) * travel
                    : base.frame.midX - base.frame.width * AppSpaceGeometry.depthOffset(level)
            }
            let scale = interpolateDepth(depth) { level in
                1 - CGFloat(max(0, level)) * AppSpaceGeometry.depthScaleStep
            }
            let width = base.frame.width * scale
            let height = base.frame.height * scale
            return Card(item: item,
                frame: CGRect(x: center - width / 2 + (target == selected ? CGFloat(offset) * travel : 0),
                    y: base.frame.midY - height / 2, width: width, height: height),
                cornerRadius: base.cornerRadius * scale, opacity: 1, depth: depth)
        }
        guard cards.allSatisfy({
            [$0.frame.minX, $0.frame.minY, $0.frame.maxX, $0.frame.maxY, $0.cornerRadius].allSatisfy(\.isFinite)
                && $0.frame.width > 0 && $0.frame.height > 0 && $0.cornerRadius >= 0
        }) else { return nil }
        return Layout(cards: cards, travel: travel)
    }

    // Shared endpoint tangents keep a card's velocity continuous as it passes
    // the front of the stack and the bounded neighborhood advances by one item.
    private static func interpolateDepth(_ depth: Double, value: (Int) -> CGFloat) -> CGFloat {
        let index = Int(floor(depth))
        let t = CGFloat(depth - Double(index))
        let a = value(index), b = value(index + 1)
        func tangent(_ left: CGFloat, _ right: CGFloat) -> CGFloat {
            guard left * right > 0 else { return 0 }
            return 2 * left * right / (left + right)
        }
        let start = tangent(a - value(index - 1), b - a)
        let end = tangent(b - a, value(index + 2) - b)
        let square = t * t, cube = square * t
        return (2 * cube - 3 * square + 1) * a + (cube - 2 * square + t) * start
            + (-2 * cube + 3 * square) * b + (cube - square) * end
    }

    static func pose(for card: Card, size: CGSize, safeArea: UIEdgeInsets) -> SurfaceGeometry.Pose? {
        let frame = card.frame
        guard SurfaceGeometry.resolve(size: size, safeArea: safeArea, request: .full) != nil,
              [frame.minX, frame.minY, frame.maxX, frame.maxY, frame.width, frame.height, card.cornerRadius].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0, card.cornerRadius >= 0,
              card.cornerRadius <= min(frame.width, frame.height) / 2 else { return nil }
        let safeWidth = size.width - safeArea.left - safeArea.right
        let safeHeight = size.height - safeArea.top - safeArea.bottom
        // Same uniform cover/crop as Lift, but horizontal browse may intentionally
        // move outside the safe viewport. Lift's contained-target contract stays intact.
        let scale = max(frame.width / size.width, frame.height / size.height)
        let pose = SurfaceGeometry.Pose(scale: scale,
            translation: CGSize(width: (frame.midX - size.width / 2) / safeWidth,
                height: (frame.midY - size.height / 2) / safeHeight),
            cornerRadius: card.cornerRadius / scale,
            clipFraction: CGSize(width: min(1, frame.width / (size.width * scale)),
                height: min(1, frame.height / (size.height * scale))))
        return pose.isValid ? pose : nil
    }
}
