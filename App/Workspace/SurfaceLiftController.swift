import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class SurfaceLiftController {
    private(set) var state = SurfaceLiftState()
    private(set) var overlayPresented = false
    private var selectedSources: Set<String> = []
    var minimumCardSize = CGSize(width: 220, height: 300)

    var hasSelection: Bool { !selectedSources.isEmpty }

    // Compilable RED transport: state evolves but no host is presented or animated.
    func bind<Content: View>(_ host: ConversationSurfaceViewController<Content>) {}
    func canArm(_ input: SurfaceLiftEligibility) -> Bool {
        state.phase == .full && input.allowsLift && !overlayPresented && !hasSelection
    }
    func arm(_ input: SurfaceLiftEligibility, at point: CGPoint = .zero) -> Bool {
        state.arm(input)
    }
    func drag(upwardDistance: Double, eligibility: SurfaceLiftEligibility) -> Bool {
        state.drag(upwardDistance: upwardDistance, eligibility: eligibility)
    }
    @discardableResult
    func end(cancelled: Bool = false, animated: Bool = true) -> SurfaceLiftState.Settlement? {
        state.end(cancelled: cancelled)
    }
    @discardableResult
    func returnToFull(animated: Bool = true) -> Bool {
        state.requestReturn() != nil
    }
    func invalidate() { state.interrupt() }
    func setOverlayPresented(_ value: Bool) { overlayPresented = value }
    func setSelection(sourceID: String, active: Bool) {
        if active { selectedSources.insert(sourceID) } else { selectedSources.remove(sourceID) }
    }
}
