import UIKit

/// Captured before async preparation; the prepared Pane can be the Lift origin
/// even when the selected Card is already owned by the opposite physical host.
struct WorkspaceReturnPlan: Equatable {
    let originSlot: WorkspaceSurfaceSlot
    let targetSurfaceSlot: WorkspaceSurfaceSlot
    let targetLogicalSlot: SplitDropSlot?
    let arrangement: SplitWorkspaceState?
    let presentation: WorkspaceDevicePresentation
    var holdsPreviewThroughReturn: Bool { originSlot != targetSurfaceSlot }

    static func resolve(split: SplitWorkspaceState?, sourceSurfaceSlot: WorkspaceSurfaceSlot,
                        originSlot: WorkspaceSurfaceSlot, selectedID: String?,
                        presentation: WorkspaceDevicePresentation) -> Self {
        let logical: SplitDropSlot?
        let target: WorkspaceSurfaceSlot
        if let split {
            if let selectedID, selectedID == split.sourceConversationID { logical = split.sourceSlot; target = sourceSurfaceSlot }
            else if let selectedID, selectedID == split.secondaryConversationID { logical = split.emptySlot; target = sourceSurfaceSlot.other }
            else { target = originSlot; logical = originSlot == sourceSurfaceSlot ? split.sourceSlot : split.emptySlot }
        } else { target = originSlot; logical = nil }
        return Self(originSlot: originSlot, targetSurfaceSlot: target, targetLogicalSlot: logical,
                    arrangement: split, presentation: presentation)
    }

    func destination(size: CGSize, safeArea: UIEdgeInsets) -> CGRect? {
        destination(in: CGRect(origin: .zero, size: size), safeArea: safeArea)
    }
    func destination(in frame: CGRect, safeArea: UIEdgeInsets) -> CGRect? {
        guard case .split(let axis) = presentation, let arrangement, let targetLogicalSlot else { return frame }
        let ratio = axis == .topBottom ? arrangement.topBottomRatio : arrangement.leftRightRatio
        return SplitWorkspaceGeometry(size: frame.size, safeArea: safeArea, ratio: ratio, axis: axis)?
            .frame(for: targetLogicalSlot).offsetBy(dx: frame.minX, dy: frame.minY)
    }
}
