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
                        minimumCardSize: CGSize, includesNew: Bool = false) -> Layout? { nil }
    static func pose(for card: Card, size: CGSize, safeArea: UIEdgeInsets) -> SurfaceGeometry.Pose? { nil }
}
