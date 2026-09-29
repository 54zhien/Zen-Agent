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
                        minimumCardSize: CGSize, includesNew: Bool = false) -> Layout? {
        guard offset.isFinite, abs(offset) <= 1, historyIDs.count <= 5,
              let resting = AppSpaceGeometry.resolve(size: size, safeArea: safeArea,
                historyIDs: historyIDs, current: current, minimumCardSize: minimumCardSize),
              let base = resting.cards.first(where: { $0.item == current }) else { return nil }
        let items = historyIDs.map(AppSpaceGeometry.Item.conversation)
            + (includesNew || current == .newConversation ? [.newConversation] : [])
        guard items.count <= 5, let selected = items.firstIndex(of: current) else { return nil }
        let travel = size.width - base.frame.minX + 16
        guard travel.isFinite, travel > 0 else { return nil }
        let targetIndex = selected + (offset > 0 ? -1 : offset < 0 ? 1 : 0)
        let target = items.indices.contains(targetIndex) ? targetIndex : selected

        func placements(selectedIndex: Int) -> [Card]? {
            guard let layout = AppSpaceGeometry.resolve(size: size, safeArea: safeArea,
                historyIDs: historyIDs, current: items[selectedIndex], minimumCardSize: minimumCardSize) else { return nil }
            return items.enumerated().map { index, item in
                let depth = selectedIndex - index
                if let card = layout.cards.first(where: { $0.item == item }) {
                    return Card(item: item, frame: card.frame, cornerRadius: card.cornerRadius,
                        opacity: 1, depth: Double(depth))
                }
                // Only the immediate successor enters from the right. A fourth
                // predecessor fades out without constructing an extra summary.
                if depth < 0 {
                    return Card(item: item, frame: base.frame.offsetBy(dx: travel * CGFloat(-depth), dy: 0),
                        cornerRadius: base.cornerRadius, opacity: 0, depth: Double(depth))
                }
                let scale = 1 - CGFloat(depth) * 0.04
                return Card(item: item,
                    frame: CGRect(x: base.frame.minX - 28 * CGFloat(depth),
                        y: base.frame.minY - 6 * CGFloat(depth),
                        width: base.frame.width * scale, height: base.frame.height * scale),
                    cornerRadius: base.cornerRadius * scale, opacity: 0, depth: Double(depth))
            }
        }
        guard let start = placements(selectedIndex: selected), let end = placements(selectedIndex: target) else { return nil }
        let progress = CGFloat(abs(offset))
        func interpolate(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (1 - progress) * a + progress * b }
        let cards = zip(start, end).map { a, b in
            Card(item: a.item,
                frame: CGRect(x: interpolate(a.frame.minX, b.frame.minX), y: interpolate(a.frame.minY, b.frame.minY),
                    width: interpolate(a.frame.width, b.frame.width), height: interpolate(a.frame.height, b.frame.height))
                    .offsetBy(dx: target == selected ? CGFloat(offset) * travel : 0, dy: 0),
                cornerRadius: interpolate(a.cornerRadius, b.cornerRadius),
                opacity: Double(interpolate(CGFloat(a.opacity), CGFloat(b.opacity))),
                depth: Double(interpolate(CGFloat(a.depth), CGFloat(b.depth))))
        }
        guard cards.allSatisfy({
            [$0.frame.minX, $0.frame.minY, $0.frame.maxX, $0.frame.maxY, $0.cornerRadius].allSatisfy(\.isFinite)
                && $0.frame.width > 0 && $0.frame.height > 0 && $0.cornerRadius >= 0
        }) else { return nil }
        return Layout(cards: cards, travel: travel)
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
