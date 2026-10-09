import Foundation

struct SurfaceLiftEligibility: Equatable, Sendable {
    var isEditing = false
    var hasMarkedText = false
    var keyboardVisible = false
    var keyboardTransitioning = false
    var composerSettled = true
    var selectionActive = false
    var quoteDragActive = false
    var overlayPresented = false

    var allowsLift: Bool {
        !isEditing && !hasMarkedText && !keyboardVisible && !keyboardTransitioning
            && composerSettled && !selectionActive && !quoteDragActive && !overlayPresented
    }
}

struct SurfaceLiftState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case full, armed, lifting, settling, card, split }
    enum Destination: Equatable, Sendable { case full, card, split }
    struct Settlement: Equatable, Sendable {
        let identity: UUID
        let destination: Destination
        let startProgress: Double
    }

    private(set) var phase: Phase = .full
    private(set) var progress: Double = 0
    private(set) var pendingSettlement: Settlement?

    mutating func arm(_ eligibility: SurfaceLiftEligibility) -> Bool {
        guard phase == .full, eligibility.allowsLift else { return false }
        phase = .armed
        return true
    }

    mutating func drag(upwardDistance: Double, eligibility: SurfaceLiftEligibility) -> Bool {
        guard phase == .armed || phase == .lifting else { return false }
        guard eligibility.allowsLift else {
            interrupt()
            return false
        }
        guard upwardDistance.isFinite else { return false }
        // Calibration starts here; production comfort is measured on devices later.
        let onset = 12.0
        let fullDistance = 180.0
        if phase == .armed, upwardDistance < onset { return true }
        phase = .lifting
        progress = min(1, max(0, (upwardDistance - onset) / (fullDistance - onset)))
        return true
    }

    mutating func end(cancelled: Bool = false) -> Settlement? {
        if phase == .armed {
            interrupt()
            return nil
        }
        guard phase == .lifting else { return nil }
        return settle(toward: !cancelled && progress >= 0.5 ? .card : .full)
    }

    mutating func endForSplit() -> Settlement? {
        guard phase == .lifting else { return nil }
        return settle(toward: .split)
    }

    mutating func requestReturn(visibleProgress: Double? = nil) -> Settlement? {
        if let visibleProgress, !visibleProgress.isFinite { return nil }
        guard phase == .card || phase == .split || phase == .settling || phase == .lifting else { return nil }
        // UIKit captures the actual visible position before stopping an animator;
        // its model endpoint may already be Card while pixels are still in transit.
        if let visibleProgress { progress = min(1, max(0, visibleProgress)) }
        return settle(toward: .full)
    }

    mutating func complete(_ settlement: Settlement, finished: Bool) -> Bool {
        guard phase == .settling, pendingSettlement == settlement else { return false }
        if !finished {
            interrupt()
            return true
        }
        progress = settlement.destination == .full ? 0 : 1
        switch settlement.destination {
        case .full: phase = .full
        case .card: phase = .card
        case .split: phase = .split
        }
        pendingSettlement = nil
        return true
    }

    mutating func restoreCard() {
        phase = .card
        progress = 1
        pendingSettlement = nil
    }

    mutating func interrupt() {
        phase = .full
        progress = 0
        pendingSettlement = nil
    }

    private mutating func settle(toward destination: Destination) -> Settlement {
        let settlement = Settlement(identity: UUID(), destination: destination, startProgress: progress)
        phase = .settling
        pendingSettlement = settlement
        return settlement
    }
}
