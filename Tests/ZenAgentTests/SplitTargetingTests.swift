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
        #expect(targeting.update(point: CGPoint(x: CGFloat.nan, y: 180), viewport: viewport,
                                 liftProgress: 0.8).slot == nil)
        #expect(targeting.update(point: CGPoint(x: 200, y: 180), viewport: viewport,
                                 liftProgress: 0.8).slot == .top)
        #expect(targeting.end(cancelled: true) == nil)
        #expect(targeting.end(cancelled: false) == nil)
    }

    @Test func targetPreviewIsTheCommittedFullBleedPane() throws {
        let size = CGSize(width: 400, height: 800)
        let safe = UIEdgeInsets(top: 50, left: 10, bottom: 30, right: 10)
        let committed = try #require(SplitWorkspaceGeometry(viewport: CGRect(origin: .zero, size: size), ratio: 0.5))
        for slot in [SplitDropSlot.top, .bottom] {
            let preview = try #require(SplitTargetingGeometry.preview(slot: slot, progress: 1,
                size: size, safeArea: safe))
            // The drop must not jump: the preview already is the Pane the
            // Workspace commits, including its exterior screen edges.
            #expect(preview.paneFrame == committed.frame(for: slot))
            #expect(preview.paneFrame.intersection(preview.guideFrame).isEmpty)
            #expect(preview.pose.isValid)
            let pixels = try #require(SurfaceGeometry.resolve(size: size, safeArea: safe,
                request: .init(to: preview.pose, progress: 1)))
            let visible = CGSize(width: size.width * pixels.scale * pixels.clipFraction.width,
                                 height: size.height * pixels.scale * pixels.clipFraction.height)
            #expect(abs(visible.width - preview.paneFrame.width) < 0.5)
            #expect(abs(visible.height - preview.paneFrame.height) < 0.5)
            let center = CGPoint(x: size.width / 2 + pixels.translation.width,
                                 y: size.height / 2 + pixels.translation.height)
            #expect(abs(center.y - preview.paneFrame.midY) < 0.5)
            #expect(abs(pixels.cornerRadius * pixels.scale - SplitTargetingGeometry.paneCornerRadius) < 0.01)
        }
    }

    @Test func unusableGeometryHasNoPreview() {
        #expect(SplitTargetingGeometry.preview(slot: .top, progress: 0.85,
            size: .zero, safeArea: .zero) == nil)
        #expect(SplitTargetingGeometry.preview(slot: .top, progress: .nan,
            size: CGSize(width: 400, height: 800), safeArea: .zero) == nil)
        #expect(SplitTargetingGeometry.preview(slot: .bottom, progress: 0.85,
            size: CGSize(width: 400, height: 300), safeArea: .zero) == nil)
    }
}
