import UIKit

struct SplitWorkspaceGeometry {
    let viewport: CGRect
    let top: CGRect
    let bottom: CGRect
    let divider: CGRect

    init?(size: CGSize, safeArea: UIEdgeInsets, ratio: Double, axis: SplitWorkspaceAxis = .topBottom) {
        guard size.width.isFinite, size.height.isFinite, ratio.isFinite,
              ratio > 0, ratio < 1,
              [safeArea.top, safeArea.left, safeArea.bottom, safeArea.right].allSatisfy({ $0.isFinite })
        else { return nil }
        let rect = CGRect(origin: .zero, size: size).inset(by: safeArea)
        self.init(viewport: rect, ratio: ratio, axis: axis)
    }

    init?(viewport rect: CGRect, ratio: Double, axis: SplitWorkspaceAxis = .topBottom) {
        guard ratio.isFinite, ratio > 0, ratio < 1,
              rect.size.width > 0, rect.size.height > 0,
              [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
               rect.maxX, rect.maxY].allSatisfy({ $0.isFinite }) else { return nil }
        viewport = rect
        let length = axis == .topBottom ? rect.height : rect.width
        let gap = min(12, length * min(ratio, 1 - ratio))
        if axis == .topBottom {
            let boundary = rect.minY + rect.height * ratio
            top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: boundary - rect.minY - gap / 2)
            divider = CGRect(x: rect.minX, y: boundary - gap / 2, width: rect.width, height: gap)
            bottom = CGRect(x: rect.minX, y: divider.maxY, width: rect.width, height: rect.maxY - divider.maxY)
        } else {
            let boundary = rect.minX + rect.width * ratio
            top = CGRect(x: rect.minX, y: rect.minY, width: boundary - rect.minX - gap / 2, height: rect.height)
            divider = CGRect(x: boundary - gap / 2, y: rect.minY, width: gap, height: rect.height)
            bottom = CGRect(x: divider.maxX, y: rect.minY, width: rect.maxX - divider.maxX, height: rect.height)
        }
    }

    func frame(for slot: SplitDropSlot) -> CGRect { slot == .top ? top : bottom }

    // Calibration starts from room for navigation, Composer and a reading area.
    // Very small windows reduce the minimum symmetrically instead of creating
    // an impossible clamp range. Device comfort remains a separate gate.
    static func minimumRatio(height: Double, preferredMinimum: Double) -> Double {
        min(0.45, max(0.1, preferredMinimum / height))
    }

    static func projectedRatio(_ raw: Double, minimum: Double) -> Double {
        if raw < minimum { return max(0.04, minimum + (raw - minimum) * 0.22) }
        if raw > 1 - minimum { return min(0.96, 1 - minimum + (raw - (1 - minimum)) * 0.22) }
        return raw
    }

    static func snappedRatio(_ ratio: Double, minimum: Double) -> Double {
        let clamped = min(1 - minimum, max(minimum, ratio))
        let stops = [1.0 / 3, 0.5, 2.0 / 3]
        return stops.first { abs($0 - clamped) < 0.018 && $0 >= minimum && $0 <= 1 - minimum } ?? clamped
    }
}
