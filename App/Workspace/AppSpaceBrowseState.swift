import Foundation

struct AppSpaceBrowseState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, dragging, settling }
    struct Settlement: Equatable, Sendable {
        let identity: UUID
        let destination: AppSpaceGeometry.Item
        let startOffset: Double
        let endOffset: Double
    }
    private(set) var selected: AppSpaceGeometry.Item
    private(set) var older: AppSpaceGeometry.Item?
    private(set) var newer: AppSpaceGeometry.Item?
    private(set) var phase: Phase = .idle
    private(set) var offset: Double = 0
    private(set) var pendingSettlement: Settlement?

    init(selected: AppSpaceGeometry.Item, older: AppSpaceGeometry.Item?, newer: AppSpaceGeometry.Item?) {
        self.selected = selected; self.older = older; self.newer = newer
    }
    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .dragging
        return true
    }

    mutating func drag(displacement: Double, travel: Double) -> Bool {
        guard phase == .dragging, displacement.isFinite, travel.isFinite, travel > 0 else { return false }
        let normalized = min(1, max(-1, displacement / travel))
        let available = normalized >= 0 ? older != nil : newer != nil
        offset = available ? normalized : normalized * 0.12
        return true
    }

    mutating func end(velocity: Double, travel: Double, cancelled: Bool = false) -> Settlement? {
        guard phase == .dragging, velocity.isFinite, travel.isFinite, travel > 0 else { return nil }
        // Device calibration remains open. Velocity affects direction, never the
        // number of conversations crossed; neighbors are frozen for this gesture.
        let projected = offset + min(1, max(-1, velocity / travel * 0.18))
        let destination: AppSpaceGeometry.Item
        let endpoint: Double
        if !cancelled, projected >= 0.22, let older { destination = older; endpoint = 1 }
        else if !cancelled, projected <= -0.22, let newer { destination = newer; endpoint = -1 }
        else { destination = selected; endpoint = 0 }
        let settlement = Settlement(identity: UUID(), destination: destination,
            startOffset: offset, endOffset: endpoint)
        pendingSettlement = settlement
        phase = .settling
        offset = endpoint
        return settlement
    }

    mutating func complete(_ settlement: Settlement, finished: Bool) -> Bool {
        guard phase == .settling, pendingSettlement == settlement else { return false }
        if finished { selected = settlement.destination }
        cancel()
        return true
    }

    mutating func cancel() {
        phase = .idle
        offset = 0
        pendingSettlement = nil
    }
}
