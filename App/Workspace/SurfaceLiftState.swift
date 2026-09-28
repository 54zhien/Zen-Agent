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
    enum Phase: Equatable, Sendable { case full, armed, lifting, settling, card }
    enum Destination: Equatable, Sendable { case full, card }
    struct Settlement: Equatable, Sendable {
        let identity: UUID
        let destination: Destination
        let startProgress: Double
    }

    private(set) var phase: Phase = .full
    private(set) var progress: Double = 0
    private(set) var pendingSettlement: Settlement?

    // Deliberate compilable RED mutation: long press incorrectly commits Card.
    mutating func arm(_ eligibility: SurfaceLiftEligibility) -> Bool {
        phase = .card
        progress = 1
        return true
    }

    mutating func drag(upwardDistance: Double, eligibility: SurfaceLiftEligibility) -> Bool { false }
    mutating func end(cancelled: Bool = false) -> Settlement? { nil }
    mutating func requestReturn(visibleProgress: Double? = nil) -> Settlement? { nil }
    mutating func complete(_ settlement: Settlement, finished: Bool) -> Bool { false }
    mutating func interrupt() {
        phase = .full
        progress = 0
        pendingSettlement = nil
    }
}
