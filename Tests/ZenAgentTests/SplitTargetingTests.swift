import UIKit
import Testing
@testable import ZenAgent

@Suite("Split target selection and live Surface geometry")
struct SplitTargetingTests {
    private let viewport = CGRect(x: 0, y: 50, width: 400, height: 700)

    @Test func topBottomAndNeutralFollowTheFingerWithoutRepeatedEntry() {
        var targeting = SplitTargetingState()
        let top = CGPoint(x: 200, y: 180)
        let bottom = CGPoint(x: 200, y: 630)
        let middle = CGPoint(x: 200, y: 400)
        #expect(targeting.update(point: top, viewport: viewport, liftProgress: 0.7)
            == .init(slot: .top, enteredTarget: true))
        #expect(targeting.update(point: top, viewport: viewport, liftProgress: 0.8)
            == .init(slot: .top, enteredTarget: false))
        #expect(targeting.update(point: middle, viewport: viewport, liftProgress: 0.8)
            == .init(slot: nil, enteredTarget: false))
        #expect(targeting.update(point: bottom, viewport: viewport, liftProgress: 0.8)
            == .init(slot: .bottom, enteredTarget: true))
        #expect(targeting.end(cancelled: false) == .bottom)
    }

    @Test func cancellationAndInvalidViewportCannotCommitATarget() {
        var targeting = SplitTargetingState()
        #expect(targeting.update(point: CGPoint(x: 200, y: 180), viewport: viewport,
                                 liftProgress: 0.2).slot == nil)
        #expect(targeting.update(point: CGPoint(x: 200, y: 180), viewport: .zero,
                                 liftProgress: 0.8).slot == nil)
        #expect(targeting.update(point: CGPoint(x: .nan, y: 180), viewport: viewport,
                                 liftProgress: 0.8).slot == nil)
        #expect(targeting.update(point: CGPoint(x: 200, y: 180), viewport: viewport,
                                 liftProgress: 0.8).slot == .top)
        #expect(targeting.end(cancelled: true) == nil)
        #expect(targeting.end(cancelled: false) == nil)
    }

    @Test func targetPreviewStaysInsideSafeViewportAndNearlyReachesItsPane() throws {
        let size = CGSize(width: 400, height: 800)
        let safe = UIEdgeInsets(top: 50, left: 10, bottom: 30, right: 10)
        let safeFrame = CGRect(x: 10, y: 50, width: 380, height: 720)
        for slot in [SplitDropSlot.top, .bottom] {
            let final = try #require(SplitTargetingGeometry.preview(slot: slot, progress: 1,
                size: size, safeArea: safe))
            let live = try #require(SplitTargetingGeometry.preview(slot: slot, progress: 0.85,
                size: size, safeArea: safe))
            #expect(safeFrame.contains(final.paneFrame))
            #expect(safeFrame.contains(final.guideFrame))
            #expect(final.paneFrame.intersection(final.guideFrame).isEmpty)
            #expect(final.pose.isValid && live.pose.isValid)
            let finalPixels = try #require(SurfaceGeometry.resolve(size: size, safeArea: safe,
                request: .init(to: final.pose, progress: 1)))
            let livePixels = try #require(SurfaceGeometry.resolve(size: size, safeArea: safe,
                request: .init(to: live.pose, progress: 1)))
            let remaining = abs(finalPixels.translation.height - livePixels.translation.height)
            let total = abs(finalPixels.translation.height)
            #expect(remaining <= total * 0.2 + 1)
        }
    }

    @Test func unusableGeometryHasNoPreview() {
        #expect(SplitTargetingGeometry.preview(slot: .top, progress: 0.85,
            size: .zero, safeArea: .zero) == nil)
        #expect(SplitTargetingGeometry.preview(slot: .top, progress: .nan,
            size: CGSize(width: 400, height: 800), safeArea: .zero) == nil)
        #expect(SplitTargetingGeometry.preview(slot: .bottom, progress: 0.85,
            size: CGSize(width: 400, height: 800),
            safeArea: UIEdgeInsets(top: 400, left: 0, bottom: 400, right: 0)) == nil)
    }
}
